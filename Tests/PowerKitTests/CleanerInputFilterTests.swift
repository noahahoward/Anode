import XCTest
import Carbon.HIToolbox
@testable import AnodeApp

/// What the keyboard cleaner lets through: nothing, except the combination that ends it and the release of a key
/// that was already held when it began (so no app is left believing a key is stuck down).
final class CleanerInputFilterTests: XCTestCase {

    private let exit = Shortcut(key: kVK_Escape, carbon: controlKey | optionKey | cmdKey)
    private let exitFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]

    private func filter(held: Set<Int> = []) -> CleanerInputFilter {
        CleanerInputFilter(exit: exit, keysDownAtStart: held)
    }

    private func ev(_ kind: CleanerEvent.Kind, _ key: Int = kVK_ANSI_A, _ flags: CGEventFlags = []) -> CleanerEvent {
        CleanerEvent(kind: kind, key: key, flags: flags)
    }

    func testEverythingIsSwallowedByDefault() {
        let f = filter()
        XCTAssertEqual(f.verdict(for: ev(.keyDown)), .swallow)
        XCTAssertEqual(f.verdict(for: ev(.keyUp)), .swallow)
        XCTAssertEqual(f.verdict(for: ev(.flagsChanged, kVK_Shift, .maskShift)), .swallow)
        XCTAssertEqual(f.verdict(for: ev(.other, 0)), .swallow)
    }

    func testExitCombinationEnds() {
        XCTAssertEqual(filter().verdict(for: ev(.keyDown, kVK_Escape, exitFlags)), .exit)
    }

    func testExitNeedsExactlyThoseModifiers() {
        let f = filter()
        XCTAssertEqual(f.verdict(for: ev(.keyDown, kVK_Escape, exitFlags.union(.maskShift))), .swallow)
        XCTAssertEqual(f.verdict(for: ev(.keyDown, kVK_Escape, [.maskControl, .maskAlternate])), .swallow)
        XCTAssertEqual(f.verdict(for: ev(.keyDown, kVK_ANSI_A, exitFlags)), .swallow)
    }

    func testExitIgnoresCapsLockAndFnFlags() {
        let flags = exitFlags.union(.maskAlphaShift).union(.maskSecondaryFn)
        XCTAssertEqual(filter().verdict(for: ev(.keyDown, kVK_Escape, flags)), .exit)
    }

    func testKeyUpOfAKeyHeldAtStartPassesOnce() {
        let f = filter(held: [kVK_Command])
        XCTAssertEqual(f.verdict(for: ev(.keyUp, kVK_Command)), .pass)
        XCTAssertEqual(f.verdict(for: ev(.keyUp, kVK_Command)), .swallow)
    }

    /// A modifier is released with a flags-changed event, not a key-up.
    func testModifierReleaseHeldAtStartPassesOnce() {
        let f = filter(held: [kVK_Command])
        XCTAssertEqual(f.verdict(for: ev(.flagsChanged, kVK_Command, [])), .pass)
        XCTAssertEqual(f.verdict(for: ev(.flagsChanged, kVK_Command, .maskCommand)), .swallow)
    }

    func testKeyDownOfAHeldKeyIsStillSwallowed() {
        let f = filter(held: [kVK_ANSI_A])
        XCTAssertEqual(f.verdict(for: ev(.keyDown, kVK_ANSI_A)), .swallow)
        XCTAssertEqual(f.verdict(for: ev(.keyUp, kVK_ANSI_A)), .pass)
    }

    func testExitKeyUpIsSwallowed() {
        let f = filter()
        XCTAssertEqual(f.verdict(for: ev(.keyDown, kVK_Escape, exitFlags)), .exit)
        XCTAssertEqual(f.verdict(for: ev(.keyUp, kVK_Escape, exitFlags)), .swallow)
    }
}
