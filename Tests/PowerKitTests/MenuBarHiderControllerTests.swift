import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// The menu bar hider's controller with the reader, the covers, the pill, the chevron and Anode's widgets all faked: nothing
/// here creates a window, a status item or an accessibility call.
final class MenuBarHiderControllerTests: XCTestCase {

    final class FakeReader: BarReading {
        var queue: [[BarItem]?] = []
        var fallback: [BarItem]? = []
        var reads = 0
        var pressed: [BarItem] = []
        func read(completion: @escaping ([BarItem]?) -> Void) {
            reads += 1
            completion(queue.isEmpty ? fallback : queue.removeFirst())
        }
        func press(_ item: BarItem) { pressed.append(item) }
    }

    final class FakeCovers: CoverPresenting {
        private(set) var rects: [CGRect] = []
        var removeCount = 0
        func show(_ rects: [CGRect], on screen: CGRect) { self.rects = rects }
        func removeAll() { rects = []; removeCount += 1 }
    }

    final class FakePill: PillPresenting {
        private(set) var isShowing = false
        var shown: [[String]] = []
        var press: ((BarItem) -> Void)?
        func show(items: [BarItem], origin: CGPoint?, press: @escaping (BarItem) -> Void) {
            isShowing = true; shown.append(items.map(\.key)); self.press = press
        }
        func hide() { isShowing = false }
    }

    final class FakeChevron: ChevronPresenting {
        var installed = false
        var onToggle: (() -> Void)?
        func install() { installed = true }
        func remove() { installed = false }
    }

    final class FakeWidgets: WidgetFolding {
        var folded: Set<String> = []
        var opened: [String] = []
        var widgetKeys: [(key: String, metricID: String, title: String)] = [
            (MenuBarWidgetController.key(forMetricID: "cpuUsage"), "cpuUsage", "CPU"),
            (MenuBarWidgetController.key(forMetricID: "memoryUsage"), "memoryUsage", "Memory")]
        func setFolded(_ ids: Set<String>) { folded = ids }
        func openWidgetMenu(metricID: String) { opened.append(metricID) }
    }

    private let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var settings: Settings!
    private let reader = FakeReader(), covers = FakeCovers(), pill = FakePill(), chevron = FakeChevron(), widgets = FakeWidgets()
    private var env = HiderEnvironment(trusted: true, fullScreen: false, secondsSinceChange: 60,
                                       screen: CGRect(x: 0, y: 0, width: 1800, height: 1169),
                                       notch: CGRect(x: 790, y: 0, width: 220, height: 37), menuBarHeight: 37)
    private var clock = Date(timeIntervalSince1970: 1_000_000)
    private var logged: [String] = []
    private var controller: MenuBarHiderController!

    private func item(_ key: String, _ x: CGFloat, w: CGFloat = 40, pid: pid_t = 100, locked: Bool = false) -> BarItem {
        BarItem(key: key, bundleID: nil, appName: "A", title: key, frame: CGRect(x: x, y: 0, width: w, height: 37),
                isLocked: locked, hasPress: true, pid: pid)
    }

    /// The owner's shape: a hidden third-party icon, then battery, sound, Wi-Fi, Control Center and the clock.
    private var layout: [BarItem] {
        [item("op|1Password", 1114), item("wg|WireGuard", 1160),
         item("cc|Wi-Fi", 1507), item("cc|Sound", 1550), item("cc|Battery", 1600),
         item("cc|Control Center", 1700, locked: true), item("cc|Clock", 1740, locked: true)]
    }

    override func setUpWithError() throws {
        (defaults, suiteName) = try TestDefaults.make(owner: "MenuBarHiderController", test: name)
        settings = Settings(defaults: defaults)
        reader.fallback = layout
        controller = MenuBarHiderController(settings: settings, reader: reader, covers: covers, pill: pill, chevron: chevron,
                                            widgets: widgets, environment: { [unowned self] in self.env },
                                            now: { [unowned self] in self.clock }, ownPID: 777, log: { [unowned self] in self.logged.append($0) })
    }

    override func tearDownWithError() throws {
        controller?.shutdown()
        controller = nil
        TestDefaults.destroy(defaults, suiteName)
    }

    private func turnOn() { settings.menuBarHiderEnabled = true; controller.reevaluate() }

    func testOffRemovesEverythingAndUnfolds() {
        controller.reevaluate()
        XCTAssertEqual(controller.decision, .standDown(.disabled))
        XCTAssertFalse(chevron.installed)
        XCTAssertEqual(covers.rects, [])
        XCTAssertEqual(widgets.folded, [])
        XCTAssertEqual(reader.reads, 0, "nothing is read while the feature is off")
    }

    func testCollapsedInstallsChevronAndPlansCovers() {
        turnOn()
        XCTAssertEqual(controller.decision, .collapsed)
        XCTAssertTrue(controller.isCollapsed)
        XCTAssertTrue(chevron.installed)
        // 1Password and WireGuard are behind the chevron: one run, x 1114-1200.
        XCTAssertEqual(covers.rects.count, 1)
        XCTAssertEqual(covers.rects[0].minX, 1111, accuracy: 0.01)
        XCTAssertEqual(covers.rects[0].maxX, 1203, accuracy: 0.01)
        XCTAssertNotNil(settings.menuBarHiderArrangement, "the first arrangement is stored")
    }

    func testRefusalsRemoveCovers() {
        turnOn()
        XCTAssertFalse(covers.rects.isEmpty)
        env.trusted = false; controller.reevaluate()
        XCTAssertEqual(controller.decision, .standDown(.noAccessibility)); XCTAssertEqual(covers.rects, [])
        env.trusted = true; controller.reevaluate()
        XCTAssertFalse(covers.rects.isEmpty)
        env.fullScreen = true; controller.reevaluate()
        XCTAssertEqual(controller.decision, .standDown(.fullScreen)); XCTAssertEqual(covers.rects, [])
        env.fullScreen = false; controller.reevaluate()
        env.secondsSinceChange = 0.2; controller.reevaluate()
        XCTAssertEqual(controller.decision, .standDown(.settling)); XCTAssertEqual(covers.rects, [])
        env.secondsSinceChange = 60; controller.reevaluate()
        XCTAssertFalse(covers.rects.isEmpty)
        reader.fallback = [item("op|1Password", -100)]   // nothing on the bar of this screen
        controller.reevaluate()
        XCTAssertEqual(controller.decision, .standDown(.itemsNotOnThisScreen)); XCTAssertEqual(covers.rects, [])
        XCTAssertTrue(chevron.installed, "the chevron stays when the hider stands down")
    }

    func testFailedReadRemovesCoverNotKeepsIt() {
        turnOn()
        XCTAssertFalse(covers.rects.isEmpty)
        reader.fallback = nil
        controller.layoutMayHaveChanged()
        XCTAssertEqual(controller.decision, .standDown(.layoutUnreadable))
        XCTAssertEqual(covers.rects, [])
    }

    func testLayoutChangedBetweenReadAndShowRereads() {
        turnOn()
        let reads = reader.reads
        XCTAssertEqual(reads, 2, "two agreeing reads before anything is covered")
        var moved = layout; moved[0].frame.origin.x = 1000; moved[1].frame.origin.x = 1046
        reader.queue = [moved, moved]
        controller.layoutMayHaveChanged()
        XCTAssertEqual(reader.reads, reads + 2)
        XCTAssertEqual(covers.rects[0].minX, 997, accuracy: 0.01)
        // Two reads that disagree: no cover rather than a stale one.
        var other = moved; other[0].frame.origin.x = 900
        reader.queue = [other, moved]
        controller.layoutMayHaveChanged()
        XCTAssertEqual(covers.rects, [])
    }

    func testTogglePillShowsHiddenItemsInOrder() {
        settings.menuBarHiderArrangement = BarArrangement(pinned: ["cc|Wi-Fi", "cc|Sound", "cc|Battery"],
                                                          pillOrder: ["wg|WireGuard", "op|1Password"])
        turnOn()
        controller.togglePill()
        XCTAssertTrue(pill.isShowing)
        let keys = pill.shown.last ?? []
        XCTAssertEqual(Array(keys.prefix(2)), ["wg|WireGuard", "op|1Password"])
        XCTAssertTrue(keys.contains(MenuBarWidgetController.key(forMetricID: "cpuUsage")))
        XCTAssertFalse(keys.contains("cc|Clock"))
        controller.togglePill()
        XCTAssertFalse(pill.isShowing)
    }

    func testToggleDoesNothingWhileStoodDown() {
        turnOn()
        env.fullScreen = true; controller.reevaluate()
        controller.togglePill()
        XCTAssertFalse(pill.isShowing)
    }

    func testPillClosesOnScreenChange() {
        turnOn()
        controller.togglePill()
        XCTAssertTrue(pill.isShowing)
        controller.layoutMayHaveChanged(screenChanged: true)
        XCTAssertFalse(pill.isShowing)
    }

    func testPillAutoClosesOnTick() {
        settings.menuBarHiderAutoCloseSeconds = 5
        turnOn()
        controller.togglePill()
        clock = clock.addingTimeInterval(4); controller.tick()
        XCTAssertTrue(pill.isShowing)
        clock = clock.addingTimeInterval(1.5); controller.tick()
        XCTAssertFalse(pill.isShowing)
    }

    func testArrangementNamingAbsentAppIsIgnored() {
        settings.menuBarHiderArrangement = BarArrangement(pinned: ["gone|App", "cc|Wi-Fi", "cc|Sound", "cc|Battery"], pillOrder: ["gone|Other"])
        turnOn()
        XCTAssertEqual(controller.decision, .collapsed)
        controller.togglePill()
        XCTAssertFalse((pill.shown.last ?? []).contains("gone|Other"))
    }

    func testAnodeWidgetsFoldedExactlyWhenBehindChevron() {
        let cpu = MenuBarWidgetController.key(forMetricID: "cpuUsage")
        settings.menuBarHiderArrangement = BarArrangement(pinned: [cpu, "cc|Wi-Fi", "cc|Sound", "cc|Battery"], pillOrder: [])
        turnOn()
        XCTAssertEqual(widgets.folded, ["memoryUsage"], "the pinned widget stays a real status item")
    }

    func testOwnStatusItemsAreNeverCovered() {
        // Anode's own widgets and its chevron show up in the Accessibility read; they must not be planned as covers.
        reader.fallback = layout + [item("dev.anode.app|x", 1300, pid: 777)]
        turnOn()
        XCTAssertEqual(covers.rects.count, 1)
        XCTAssertLessThan(covers.rects[0].maxX, 1300)
    }

    func testPressingAnItemInThePillForwardsIt() {
        turnOn()
        controller.togglePill()
        let wg = layout[1]
        pill.press?(wg)
        XCTAssertEqual(reader.pressed.map(\.key), ["wg|WireGuard"])
        XCTAssertFalse(pill.isShowing, "pressing another app's icon closes the pill")
        controller.togglePill()
        pill.press?(BarItem(key: MenuBarWidgetController.key(forMetricID: "cpuUsage"), bundleID: "dev.anode.app", appName: "Anode",
                            title: "CPU", frame: .zero, isLocked: false, hasPress: false, pid: nil))
        XCTAssertEqual(widgets.opened, ["cpuUsage"])
        XCTAssertTrue(pill.isShowing, "Anode's own widget opens its menu and leaves the pill up")
    }

    func testTurningOffRestoresWidgets() {
        turnOn()
        XCTAssertFalse(widgets.folded.isEmpty)
        controller.togglePill()
        settings.menuBarHiderEnabled = false
        controller.reevaluate()
        XCTAssertEqual(widgets.folded, [])
        XCTAssertEqual(covers.rects, [])
        XCTAssertFalse(pill.isShowing)
        XCTAssertFalse(chevron.installed)
    }

    func testShutdownRemovesEverything() {
        turnOn()
        controller.togglePill()
        controller.shutdown()
        XCTAssertEqual(widgets.folded, [])
        XCTAssertEqual(covers.rects, [])
        XCTAssertFalse(pill.isShowing)
        XCTAssertFalse(chevron.installed)
    }

    func testReevaluateIsIdempotent() {
        turnOn()
        let rects = covers.rects
        controller.reevaluate()
        controller.reevaluate()
        XCTAssertEqual(covers.rects, rects)
        XCTAssertEqual(controller.decision, .collapsed)
    }

    func testDismissClosesThePill() {
        turnOn()
        controller.togglePill()
        controller.dismissPill()
        XCTAssertFalse(pill.isShowing)
        XCTAssertFalse(controller.isPillOpen)
        controller.dismissPill()   // already closed: nothing happens
        XCTAssertFalse(pill.isShowing)
    }

    func testChevronTogglesThePill() {
        turnOn()
        chevron.onToggle?()
        XCTAssertTrue(pill.isShowing)
    }
}
