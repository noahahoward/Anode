import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// Turning what Accessibility reports about the menu bar into `BarItem`s. Only the pure part is tested: nothing here makes an
/// accessibility call.
final class BarReaderTests: XCTestCase {

    private typealias Child = AXBarReader.Child
    private let agent = (bundleID: Optional("com.apple.MenuBarAgent"), name: "MenuBarAgent", pid: pid_t(300))

    private func child(_ id: String? = nil, title: String? = nil, desc: String? = nil, x: CGFloat, press: Bool = true) -> Child {
        Child(identifier: id, title: title, description: desc, frame: CGRect(x: x, y: 0, width: 22, height: 39), hasPress: press)
    }

    func testOrdinalsAreOrderedByX() {
        // Measured: a third-party item has no identifier, title or description. Two of them from one app are told apart by
        // their order on the bar, whatever order they are listed in.
        let items = AXBarReader.parse(app: (bundleID: "net.openvpn", name: "OpenVPN", pid: 5),
                                      children: [child(x: 900), child(x: 800)])
        XCTAssertEqual(items.map(\.key), ["net.openvpn|#0", "net.openvpn|#1"])
        XCTAssertEqual(items.map(\.frame.minX), [800, 900])
    }

    func testSameNameGetsOrdinalsOnlyAfterTheFirst() {
        let items = AXBarReader.parse(app: (bundleID: "a", name: "A", pid: 1),
                                      children: [child(title: "Menu", x: 10), child(title: "Menu", x: 40), child(title: "Other", x: 70)])
        XCTAssertEqual(items.map(\.key), ["a|Menu", "a|Menu#1", "a|Other"])
    }

    func testItemWithoutPressActionIsKept() {
        let items = AXBarReader.parse(app: agent, children: [child("com.apple.menuextra.wifi", x: 1502, press: false)])
        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(items[0].hasPress)
        XCTAssertEqual(items[0].key, "com.apple.MenuBarAgent|com.apple.menuextra.wifi")
        XCTAssertEqual(items[0].pid, 300)
    }

    func testEmptyChildrenGivesNoItems() {
        XCTAssertEqual(AXBarReader.parse(app: agent, children: []), [])
    }

    func testLockedFlagSetForClockAndControlCenter() {
        let items = AXBarReader.parse(app: agent, children: [
            child("com.apple.menuextra.wifi", x: 1502), child("com.apple.menuextra.controlcenter", x: 1620),
            child("com.apple.menuextra.clock", x: 1662)])
        XCTAssertEqual(items.map(\.isLocked), [false, true, true])
    }

    func testTitleOfAnItemIsItsDescriptionWhenThereIsNoTitle() {
        let items = AXBarReader.parse(app: (bundleID: "dev.anode.app", name: "Anode", pid: 9),
                                      children: [child(title: "", desc: "Keep Awake", x: 1067)])
        XCTAssertEqual(items[0].title, "Keep Awake")
    }

    /// Two parked items sit at the same x. Their order must come out the same wherever it is worked out, or a key is paired
    /// with the wrong element and a press hits the wrong item.
    func testOrderKeepsTheOriginalOrderForTies() {
        let kids = [child(x: 7), child(x: -1), child(x: 7), child(x: -1)]
        XCTAssertEqual(AXBarReader.order(of: kids), [1, 3, 0, 2])
    }

    /// A position, size or identifier that could not be read means the app's items are not known; the whole read then fails
    /// rather than leaving the item out and letting a cover span it.
    func testAReadThatLostSomethingIsNotComplete() {
        XCTAssertTrue(AXBarReader.isComplete([child(x: 1), child(x: 2)]))
        var bad = child(x: 3)
        bad.readFailed = true
        XCTAssertFalse(AXBarReader.isComplete([child(x: 1), bad]))
        XCTAssertTrue(AXBarReader.isComplete([]))
    }

    /// The read has a deadline on the main side; whichever of the deadline and the late result comes second is dropped.
    func testOnlyTheFirstCompletionIsDelivered() {
        var got: [[BarItem]?] = []
        let once = OnceCompletion { got.append($0) }
        XCTAssertTrue(once.complete(nil))
        XCTAssertFalse(once.complete([]))
        XCTAssertEqual(got.count, 1)
        XCTAssertNil(got[0] as Any? as? [BarItem])
    }

    // ── What an error from another app means ────────────────────────────────

    /// Only a definite "nothing here" means an app has no items. A timeout, a busy app (Anode's own items are answered by
    /// Anode's main thread) or any other error is a read that failed: leaving the app out would let a cover span its items.
    func testOnlyADefiniteNoMeansAnAppHasNoItems() {
        for status: AXError in [.noValue, .attributeUnsupported, .notImplemented] {
            XCTAssertEqual(AXBarReader.classify(status), .nothingThere, "\(status.rawValue)")
        }
        for status: AXError in [.cannotComplete, .failure, .invalidUIElement, .apiDisabled, .illegalArgument,
                                .invalidUIElementObserver, .notEnoughPrecision, .actionUnsupported] {
            XCTAssertEqual(AXBarReader.classify(status), .failed, "\(status.rawValue)")
        }
    }

    func testABarThatTimedOutFailsTheRead() {
        XCTAssertEqual(AXBarReader.bar(status: .cannotComplete, value: nil), .failed)
        XCTAssertEqual(AXBarReader.bar(status: .noValue, value: nil), .nothingThere)
        XCTAssertEqual(AXBarReader.bar(status: .success, value: nil), .failed)
    }

    /// A children read that failed is not an empty bar, even for the system's own items.
    func testChildrenThatTimedOutFailTheRead() {
        XCTAssertNil(AXBarReader.elements(status: .cannotComplete, value: nil))
        XCTAssertNil(AXBarReader.elements(status: .failure, value: nil))
        XCTAssertEqual(AXBarReader.elements(status: .noValue, value: nil)?.count, 0)
        XCTAssertEqual(AXBarReader.elements(status: .success, value: [] as CFArray)?.count, 0)
    }

    // ── Values of the wrong type from another app ───────────────────────────
    // Creating an element or a value is local; nothing here is sent to any app.

    func testABarThatIsNotAnElementFailsTheRead() {
        let element = AXUIElementCreateApplication(getpid())
        XCTAssertEqual(AXBarReader.bar(status: .success, value: element), .bar(element))
        XCTAssertEqual(AXBarReader.bar(status: .success, value: "bar" as CFString), .failed)
    }

    func testChildrenThatAreNotElementsFailTheRead() {
        let element = AXUIElementCreateApplication(getpid())
        XCTAssertEqual(AXBarReader.elements(status: .success, value: [element] as CFArray)?.count, 1)
        XCTAssertNil(AXBarReader.elements(status: .success, value: [element, "x" as CFString] as CFArray))
        XCTAssertNil(AXBarReader.elements(status: .success, value: "x" as CFString))
    }

    func testAPositionOrSizeOfTheWrongTypeIsNoFrame() {
        var p = CGPoint(x: 1114, y: 0), s = CGSize(width: 22, height: 39)
        let point = AXValueCreate(.cgPoint, &p)!, size = AXValueCreate(.cgSize, &s)!
        XCTAssertEqual(AXBarReader.frame(position: point, size: size), CGRect(x: 1114, y: 0, width: 22, height: 39))
        XCTAssertNil(AXBarReader.frame(position: size, size: size))
        XCTAssertNil(AXBarReader.frame(position: point, size: point))
        XCTAssertNil(AXBarReader.frame(position: "x" as CFString, size: size))
        XCTAssertNil(AXBarReader.frame(position: point, size: nil))
    }

    // ── The order a read is delivered in ────────────────────────────────────

    private func item(_ key: String, x: CGFloat, pid: pid_t = 1) -> BarItem {
        BarItem(key: key, bundleID: nil, appName: "A", title: "", frame: CGRect(x: x, y: 0, width: 22, height: 39),
                isLocked: false, hasPress: true, pid: pid)
    }

    /// Apps are read in parallel and answer in any order. Two reads of an unchanged bar must come out equal (they are compared
    /// to confirm a layout), and the pill and the settings list must not shuffle.
    func testItemsAreDeliveredInBarOrderWhateverOrderTheAppsAnswered() {
        let bar = [item("p|#0", x: -1, pid: 4), item("q|#0", x: -1, pid: 5), item("o|#0", x: 7, pid: 3),
                   item("a|Wi-Fi", x: 1502, pid: 2), item("b|Clock", x: 1662, pid: 2), item("anode|#0", x: 1114, pid: 9)]
        let expected = [item("p|#0", x: -1, pid: 4), item("q|#0", x: -1, pid: 5), item("o|#0", x: 7, pid: 3),
                        item("anode|#0", x: 1114, pid: 9), item("a|Wi-Fi", x: 1502, pid: 2), item("b|Clock", x: 1662, pid: 2)]
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<20 {
            XCTAssertEqual(AXBarReader.inBarOrder(bar.shuffled(using: &generator)), expected)
        }
    }

    // ── Which item a press goes to ──────────────────────────────────────────

    private func at(_ key: String, x: CGFloat, y: CGFloat = 0, pid: pid_t = 7) -> BarItem {
        BarItem(key: key, bundleID: "o", appName: "O", title: "", frame: CGRect(x: x, y: y, width: 22, height: 39),
                isLocked: false, hasPress: true, pid: pid)
    }

    func testPressGoesToTheItemWithTheKeyWhenItIsWhereItWas() {
        let now = [at("o|#0", x: 100), at("o|#1", x: 130)]
        XCTAssertEqual(AXBarReader.pressTarget(for: at("o|#1", x: 130), among: now), 1)
        // A point or two of drift (a neighbour's text changed width) is still the same item.
        XCTAssertEqual(AXBarReader.pressTarget(for: at("o|#1", x: 127), among: now), 1)
    }

    /// Unnamed items are keyed by their order. When a sibling to the left goes, the keys shift: the press must follow the
    /// item that is where the pressed one was, not the key, or it opens the other icon's menu.
    func testPressFollowsThePlaceWhenASiblingWentAndTheKeysShifted() {
        let now = [at("o|#0", x: 130)]
        XCTAssertEqual(AXBarReader.pressTarget(for: at("o|#1", x: 130), among: now), 0)
        // The item that went is not pressed by way of its old key, now worn by its sibling somewhere else.
        XCTAssertNil(AXBarReader.pressTarget(for: at("o|#0", x: 100), among: now))
    }

    func testPressDoesNothingWhenTheItemMovedAndNothingIsWhereItWas() {
        let now = [at("o|#0", x: 400), at("o|#1", x: 430)]
        XCTAssertNil(AXBarReader.pressTarget(for: at("o|#1", x: 130), among: now))
    }

    /// Parked items stack at the same place off the bar. The key tells them apart while it still matches; when it does not,
    /// several siblings sit where the item was and none can be chosen.
    func testParkedSiblingsAreToldApartByKeyAndNeverGuessed() {
        let now = [at("o|#0", x: -1, y: 1157), at("o|#1", x: -1, y: 1157)]
        XCTAssertEqual(AXBarReader.pressTarget(for: at("o|#1", x: -1, y: 1157), among: now), 1)
        XCTAssertNil(AXBarReader.pressTarget(for: at("o|#2", x: -1, y: 1157), among: now))
        // A parked item stays parked: one on the bar at the same x is not it.
        XCTAssertNil(AXBarReader.pressTarget(for: at("o|#0", x: -1, y: 1157), among: [at("o|#0", x: -1, y: 0)]))
    }

    // ── Not asking again an app that said it has no items ───────────────────

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private func cache(running: Set<pid_t>) -> NoBarCache {
        var c = NoBarCache(maxAge: 300, ownPID: 99, neverSkipped: ["com.apple.MenuBarAgent"])
        c.sync(running: running, now: t0)
        return c
    }

    /// Every read used to message every running process, waking App-Napped ones, every 30 s.
    func testAnAppThatSaidItHasNoBarIsNotAskedAgainUntilItQuits() {
        var c = cache(running: [1, 2, 3])
        c.record(pid: 2, bundleID: "b", answer: .nothingThere)
        XCTAssertTrue(c.skips(2))
        XCTAssertFalse(c.skips(1))
        c.sync(running: [1, 2, 3], now: t0 + 30)
        XCTAssertTrue(c.skips(2))
        c.sync(running: [1, 3], now: t0 + 60)
        XCTAssertFalse(c.skips(2))
    }

    /// An app that adds a status item later is still found: anything launching, or five minutes passing, starts over.
    func testALaunchOrFiveMinutesForgetsEveryAnswer() {
        var c = cache(running: [1, 2])
        c.record(pid: 1, bundleID: "a", answer: .nothingThere)
        c.sync(running: [1, 2, 4], now: t0 + 10)
        XCTAssertFalse(c.skips(1), "a launch")

        c.record(pid: 1, bundleID: "a", answer: .nothingThere)
        c.sync(running: [1, 2, 4], now: t0 + 10 + 299)
        XCTAssertTrue(c.skips(1))
        c.sync(running: [1, 2, 4], now: t0 + 10 + 300)
        XCTAssertFalse(c.skips(1), "five minutes")
    }

    /// A timeout is a failed read, never "no bar". And a "no value" from the system's items or from Anode itself (mid-rebuild)
    /// must not drop battery, Wi-Fi, sound or the chevron from every read for minutes.
    func testOnlyAnotherAppsDefiniteNoIsRemembered() {
        var c = cache(running: [1, 2, 99])
        c.record(pid: 1, bundleID: "a", answer: .failed)
        c.record(pid: 2, bundleID: "com.apple.MenuBarAgent", answer: .nothingThere)
        c.record(pid: 99, bundleID: "dev.anode.app", answer: .nothingThere)
        XCTAssertFalse(c.skips(1))
        XCTAssertFalse(c.skips(2))
        XCTAssertFalse(c.skips(99))
    }

    func testPressNeverGoesToAnotherAppsItem() {
        XCTAssertNil(AXBarReader.pressTarget(for: at("o|#1", x: 130), among: [at("p|#0", x: 130, pid: 8)]))
        // The same pid, now another app (the pid was reused): its item where the target was is not the target.
        var other = at("p|#0", x: 130)
        other.bundleID = "p"
        XCTAssertNil(AXBarReader.pressTarget(for: at("o|#1", x: 130), among: [other]))
    }

    /// A pid can be reused between drawing the pill and the press: the process must still be the item's app.
    func testPressOnlyGoesToAProcessThatIsStillTheItemsApp() {
        let item = at("o|#0", x: 100)
        XCTAssertTrue(AXBarReader.isStillTheApp(bundleID: "o", name: "O", of: item))
        XCTAssertFalse(AXBarReader.isStillTheApp(bundleID: "p", name: "O", of: item))
        XCTAssertFalse(AXBarReader.isStillTheApp(bundleID: nil, name: "O", of: item))
        // An app without a bundle id is known by its name.
        var unbundled = item
        unbundled.bundleID = nil
        XCTAssertTrue(AXBarReader.isStillTheApp(bundleID: nil, name: "O", of: unbundled))
        XCTAssertFalse(AXBarReader.isStillTheApp(bundleID: nil, name: "Other", of: unbundled))
        XCTAssertFalse(AXBarReader.isStillTheApp(bundleID: "o", name: "O", of: unbundled))
    }

    /// Seen on hardware 2026-11-11: `universalaccessd` (a system process with no menu bar items) never answers in time, and
    /// failing the read on it meant the hider never collapsed. An app's silence matters only when it may own an item: the
    /// system's owners, Anode itself, and any app seen with items before.
    func testOnlyASilentAppThatMayOwnItemsFailsTheRead() {
        let known: Set<pid_t> = [42]
        XCTAssertFalse(AXBarReader.silenceMatters(pid: 663, bundleID: "com.apple.universalaccessd", knownOwners: known, ownPID: 1))
        XCTAssertTrue(AXBarReader.silenceMatters(pid: 42, bundleID: "com.example.vpn", knownOwners: known, ownPID: 1))
        XCTAssertTrue(AXBarReader.silenceMatters(pid: 7, bundleID: "com.apple.MenuBarAgent", knownOwners: known, ownPID: 1))
        XCTAssertTrue(AXBarReader.silenceMatters(pid: 1, bundleID: "dev.anode.app", knownOwners: known, ownPID: 1))
    }
}
