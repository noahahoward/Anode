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
}
