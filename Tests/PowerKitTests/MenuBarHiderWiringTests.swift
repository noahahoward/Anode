import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// The runtime that joins the hider to the app: nothing exists while the setting is off, everything starts and stops with it.
/// All the real parts are replaced by fakes.
final class MenuBarHiderWiringTests: XCTestCase {

    private typealias Fakes = MenuBarHiderControllerTests

    final class FakeEvents: BarEventing {
        var isRunning = false
        func start() { isRunning = true }
        func stop() { isRunning = false }
    }

    private struct Rig {
        let runtime: MenuBarHiderRuntime
        let settings: Settings
        let reader: Fakes.FakeReader, covers: Fakes.FakeCovers, pill: Fakes.FakePill, chevron: Fakes.FakeChevron
        let events: FakeEvents
        let defaults: UserDefaults
        let suite: String
        let shortcut: Shortcut
    }

    final class Shortcut { var registered = false; var fire: (() -> Void)? }

    private func rig() throws -> Rig {
        let (defaults, suite) = try TestDefaults.make(owner: "MenuBarHiderWiring", test: name)
        let settings = Settings(defaults: defaults)
        let reader = Fakes.FakeReader(), covers = Fakes.FakeCovers(), pill = Fakes.FakePill(), chevron = Fakes.FakeChevron()
        reader.fallback = [BarItem(key: "op|1Password", bundleID: "op", appName: "1Password", title: "",
                                   frame: CGRect(x: 1114, y: 0, width: 40, height: 37), isLocked: false, hasPress: true, pid: 100),
                           BarItem(key: "cc|Battery", bundleID: "cc", appName: "A", title: "Battery",
                                   frame: CGRect(x: 1600, y: 0, width: 40, height: 37), isLocked: false, hasPress: true, pid: 100)]
        let events = FakeEvents()
        let shortcut = Shortcut()
        let runtime = MenuBarHiderRuntime(
            settings: settings, reader: reader, covers: covers, pill: pill, chevron: chevron, widgets: Fakes.FakeWidgets(),
            makeEvents: { _ in events },
            environment: { _ in HiderEnvironment(trusted: true, fullScreen: false, secondsSinceChange: 60,
                                                 screen: CGRect(x: 0, y: 0, width: 1800, height: 1169), notch: nil, menuBarHeight: 37) },
            registerShortcut: { fire in shortcut.registered = true; shortcut.fire = fire },
            unregisterShortcut: { shortcut.registered = false; shortcut.fire = nil },
            openBetaFeatures: {}, pillTick: {})
        return Rig(runtime: runtime, settings: settings, reader: reader, covers: covers, pill: pill, chevron: chevron,
                   events: events, defaults: defaults, suite: suite, shortcut: shortcut)
    }

    private func done(_ r: Rig) { r.runtime.shutdown(); TestDefaults.destroy(r.defaults, r.suite) }

    func testDisabledCreatesNothing() throws {
        let r = try rig(); defer { done(r) }
        XCTAssertFalse(r.chevron.installed)
        XCTAssertFalse(r.events.isRunning)
        XCTAssertFalse(r.shortcut.registered)
        XCTAssertEqual(r.reader.reads, 0)
        XCTAssertFalse(r.runtime.isTimerRunning)
    }

    func testEnablingStartsEverythingAndDisablingStopsIt() throws {
        let r = try rig(); defer { done(r) }
        r.settings.menuBarHiderEnabled = true
        XCTAssertTrue(r.chevron.installed)
        XCTAssertTrue(r.events.isRunning)
        XCTAssertTrue(r.shortcut.registered, "the toggle shortcut is listened for while the bar is collapsed")
        XCTAssertFalse(r.covers.rects.isEmpty)
        r.shortcut.fire?()
        XCTAssertTrue(r.pill.isShowing)
        r.settings.menuBarHiderEnabled = false
        XCTAssertFalse(r.chevron.installed)
        XCTAssertFalse(r.events.isRunning)
        XCTAssertFalse(r.shortcut.registered)
        XCTAssertEqual(r.covers.rects, [])
        XCTAssertFalse(r.pill.isShowing)
        XCTAssertFalse(r.runtime.isTimerRunning)
    }

    func testTheTimerRunsOnlyWhileThePillIsOpen() throws {
        let r = try rig(); defer { done(r) }
        r.settings.menuBarHiderEnabled = true
        XCTAssertFalse(r.runtime.isTimerRunning)
        r.chevron.onToggle?()
        XCTAssertTrue(r.runtime.isTimerRunning)
        r.chevron.onToggle?()
        XCTAssertFalse(r.runtime.isTimerRunning)
    }

    func testAChangedArrangementReevaluates() throws {
        let r = try rig(); defer { done(r) }
        r.settings.menuBarHiderEnabled = true
        let reads = r.reader.reads
        r.settings.menuBarHiderArrangement = BarArrangement(pinned: ["op|1Password"], pillOrder: [])
        XCTAssertGreaterThan(r.reader.reads, reads)
    }

    func testShutdownRemovesEverything() throws {
        let r = try rig(); defer { done(r) }
        r.settings.menuBarHiderEnabled = true
        r.runtime.shutdown()
        XCTAssertFalse(r.chevron.installed)
        XCTAssertFalse(r.events.isRunning)
        XCTAssertFalse(r.shortcut.registered)
        // And it no longer listens: turning the setting on again does nothing.
        r.settings.menuBarHiderEnabled = false
        r.settings.menuBarHiderEnabled = true
        XCTAssertFalse(r.chevron.installed)
    }

    func testMainWiresTheRuntimeAndShutsItDown() throws {
        let main = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AnodeApp/main.swift"), encoding: .utf8)
        XCTAssertTrue(main.contains("MenuBarHiderRuntime.live("))
        XCTAssertTrue(main.contains("menuBarHider?.shutdown()"))
    }
}
