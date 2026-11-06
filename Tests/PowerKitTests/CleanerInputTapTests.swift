import XCTest
import Carbon.HIToolbox
@testable import AnodeApp

/// What the real tap decides per event, without installing a tap. The tap itself is exercised on the Mac in the
/// plan's last task, because swallowing real input cannot be done from a test.
final class CleanerInputTapTests: XCTestCase {

    private let exit = Shortcut(key: kVK_Escape, carbon: controlKey | optionKey | cmdKey)
    private let exitFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]

    private func session(held: Set<Int> = []) -> CleanerTapSession {
        CleanerTapSession(filter: CleanerInputFilter(exit: exit, keysDownAtStart: held))
    }

    // ── Mapping a real CGEvent ──

    func testKeyboardEventsMapToTheirKindKeyCodeAndFlags() throws {
        let down = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_K), keyDown: true))
        down.flags = [.maskCommand, .maskShift]
        let e = CleanerInputTap.event(from: .keyDown, down)
        XCTAssertEqual(e.kind, .keyDown)
        XCTAssertEqual(e.key, kVK_ANSI_K)
        XCTAssertTrue(e.flags.contains(.maskCommand) && e.flags.contains(.maskShift))

        let up = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_ANSI_K), keyDown: false))
        XCTAssertEqual(CleanerInputTap.event(from: .keyUp, up).kind, .keyUp)
        XCTAssertEqual(CleanerInputTap.event(from: .flagsChanged, down).kind, .flagsChanged)
    }

    func testEverythingElseMapsToOther() throws {
        let move = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: .zero, mouseButton: .left))
        XCTAssertEqual(CleanerInputTap.event(from: .mouseMoved, move).kind, .other)
        let scroll = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0))
        XCTAssertEqual(CleanerInputTap.event(from: .scrollWheel, scroll).kind, .other)
        // A trackpad gesture: the raw type has no public name.
        let gesture = try XCTUnwrap(CGEventType(rawValue: 29))
        XCTAssertEqual(CleanerInputTap.event(from: gesture, move).kind, .other)
    }

    // ── What happens to each event ──

    func testOrdinaryEventsAreSwallowedWithoutNotice() {
        let s = session()
        let o = s.outcome(for: CleanerEvent(kind: .keyDown, key: kVK_ANSI_A, flags: []))
        XCTAssertEqual(o, CleanerTapSession.Outcome(swallow: true, disableTap: false, notice: nil))
        XCTAssertEqual(s.outcome(for: CleanerEvent(kind: .other, key: 0, flags: [])).swallow, true)
    }

    func testReleaseOfAKeyHeldAtStartPassesThrough() {
        let s = session(held: [kVK_Command])
        let o = s.outcome(for: CleanerEvent(kind: .flagsChanged, key: kVK_Command, flags: []))
        XCTAssertEqual(o, CleanerTapSession.Outcome(swallow: false, disableTap: false, notice: nil))
    }

    /// The tap thread must switch the tap off ITSELF the instant the exit combination is seen: if the main thread were
    /// stuck, waiting for it would leave every key on the Mac swallowed.
    func testExitSwitchesTheTapOffAtOnceAndNotifiesOnce() {
        let s = session()
        let first = s.outcome(for: CleanerEvent(kind: .keyDown, key: kVK_Escape, flags: exitFlags))
        XCTAssertEqual(first, CleanerTapSession.Outcome(swallow: true, disableTap: true, notice: .exit))
        let again = s.outcome(for: CleanerEvent(kind: .keyDown, key: kVK_Escape, flags: exitFlags))
        XCTAssertEqual(again, CleanerTapSession.Outcome(swallow: true, disableTap: false, notice: nil),
                       "mashing the combination notifies once")
    }

    func testTheSystemDisablingTheTapIsReportedOnceAndNeverSwallowed() {
        let s = session()
        let o = s.outcome(forDisabledTap: true)
        XCTAssertEqual(o, CleanerTapSession.Outcome(swallow: false, disableTap: false, notice: .disabled))
        XCTAssertNil(s.outcome(forDisabledTap: true).notice)
    }

    func testNothingIsReportedAfterAnExit() {
        let s = session()
        _ = s.outcome(for: CleanerEvent(kind: .keyDown, key: kVK_Escape, flags: exitFlags))
        XCTAssertNil(s.outcome(forDisabledTap: true).notice, "the session is already ending")
    }
}
