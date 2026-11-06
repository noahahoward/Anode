import XCTest
import AppKit
import Carbon.HIToolbox
@testable import AnodeApp
@testable import PowerKit

/// A cleaning session, with the tap, the windows and the sleep hold faked: nothing here touches the real keyboard,
/// the real screen or the real power state.
final class KeyboardCleanerTests: XCTestCase {

    final class FakeTap: CleanerInputTapping {
        var result = true
        var startCount = 0, stopCount = 0
        var filter: CleanerInputFilter?
        var onExit: (() -> Void)?
        var onDisabled: (() -> Void)?
        func start(filter: CleanerInputFilter, onExit: @escaping () -> Void, onDisabled: @escaping () -> Void) -> Bool {
            startCount += 1
            guard result else { return false }
            self.filter = filter; self.onExit = onExit; self.onDisabled = onDisabled
            return true
        }
        func stop() { stopCount += 1 }
    }

    final class FakeWindows: CleanerWindowPresenting {
        var shows: [String] = []
        var hideCount = 0
        private(set) var isShowing = false
        func show(hint: String, on screens: [NSScreen]) { shows.append(hint); isShowing = true }
        func hide() { hideCount += 1; isShowing = false }
    }

    final class FakeAssertions: SleepAssertions {
        var holds = 0, releases = 0
        func hold(reason: String) -> Bool { holds += 1; return true }
        func release() { releases += 1 }
    }

    final class FakeKeybinds: CleanerKeybinding {
        var command: ShortcutCommand?
        var handler: (() -> Void)?
        func register(_ command: ShortcutCommand, handler: @escaping () -> Void) { self.command = command; self.handler = handler }
        func unregister() { command = nil; handler = nil }
    }

    private struct Rig {
        let cleaner: KeyboardCleaner
        let tap: FakeTap
        let windows: FakeWindows
        let assertions: FakeAssertions
        let keybinds: FakeKeybinds
        let settings: Settings
        let store: ShortcutStore
        let trust: Box<Bool>
        let keys: Box<Set<Int>>
        let defaults: UserDefaults
        let suite: String
    }
    final class Box<T> { var value: T; init(_ v: T) { value = v } }

    private func rig() throws -> Rig {
        let (defaults, suite) = try TestDefaults.make(owner: "KeyboardCleaner", test: name)
        let settings = Settings(defaults: defaults)
        let store = ShortcutStore(defaults: defaults)
        let tap = FakeTap(), windows = FakeWindows(), assertions = FakeAssertions(), keybinds = FakeKeybinds()
        let trust = Box(true), keys = Box<Set<Int>>([])
        let cleaner = KeyboardCleaner(settings: settings, store: store, tap: tap, windows: windows, assertions: assertions,
                                      keybinds: keybinds, isTrusted: { trust.value }, screens: { NSScreen.screens },
                                      keysDown: { keys.value })
        cleaner.log = { _ in }
        return Rig(cleaner: cleaner, tap: tap, windows: windows, assertions: assertions, keybinds: keybinds,
                   settings: settings, store: store, trust: trust, keys: keys, defaults: defaults, suite: suite)
    }

    private func done(_ r: Rig) { r.cleaner.stop(); TestDefaults.destroy(r.defaults, r.suite) }

    func testStartWithoutAccessibilityDoesNothing() throws {
        let r = try rig(); defer { done(r) }
        r.trust.value = false
        XCTAssertEqual(r.cleaner.start(), .needsAccessibility)
        XCTAssertEqual(r.tap.startCount, 0)
        XCTAssertFalse(r.windows.isShowing)
        XCTAssertEqual(r.assertions.holds, 0)
        XCTAssertFalse(r.cleaner.isActive)
    }

    func testStartShowsWindowsHoldsAssertionAndTapsWithTheStoredExitCombination() throws {
        let r = try rig(); defer { done(r) }
        r.keys.value = [kVK_Command]
        XCTAssertEqual(r.cleaner.start(), .started)
        XCTAssertTrue(r.cleaner.isActive)
        XCTAssertTrue(r.windows.isShowing)
        XCTAssertTrue(r.windows.shows.last?.contains("⌃⌥⌘⎋") == true, "the hint names the exit combination")
        XCTAssertEqual(r.assertions.holds, 1)
        let f = try XCTUnwrap(r.tap.filter)
        let flags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        XCTAssertEqual(f.verdict(for: CleanerEvent(kind: .keyDown, key: kVK_Escape, flags: flags)), .exit)
        XCTAssertEqual(f.verdict(for: CleanerEvent(kind: .keyUp, key: kVK_Command, flags: [])), .pass,
                       "keys held at the start are handed to the filter")
    }

    func testTapFailingToStartUndoesEverything() throws {
        let r = try rig(); defer { done(r) }
        r.tap.result = false
        XCTAssertEqual(r.cleaner.start(), .tapUnavailable)
        XCTAssertFalse(r.windows.isShowing)
        XCTAssertEqual(r.assertions.holds, 0)
        XCTAssertFalse(r.cleaner.isActive)
    }

    func testExitCallbackEndsTheSession() throws {
        let r = try rig(); defer { done(r) }
        var changes = 0
        r.cleaner.onChange = { changes += 1 }
        _ = r.cleaner.start()
        let before = changes
        r.tap.onExit?()
        XCTAssertFalse(r.cleaner.isActive)
        XCTAssertFalse(r.windows.isShowing)
        XCTAssertEqual(r.tap.stopCount, 1)
        XCTAssertEqual(r.assertions.releases, 1)
        XCTAssertGreaterThan(changes, before)
    }

    func testTapDisabledEndsTheSession() throws {
        let r = try rig(); defer { done(r) }
        _ = r.cleaner.start()
        r.tap.onDisabled?()
        XCTAssertFalse(r.cleaner.isActive)
        XCTAssertFalse(r.windows.isShowing)
        XCTAssertEqual(r.assertions.releases, 1)
    }

    func testStartTwiceIsOneSession() throws {
        let r = try rig(); defer { done(r) }
        XCTAssertEqual(r.cleaner.start(), .started)
        XCTAssertEqual(r.cleaner.start(), .alreadyRunning)
        XCTAssertEqual(r.tap.startCount, 1)
        XCTAssertEqual(r.assertions.holds, 1)
    }

    func testStopTwiceReleasesOnce() throws {
        let r = try rig(); defer { done(r) }
        _ = r.cleaner.start()
        r.cleaner.stop(); r.cleaner.stop()
        XCTAssertEqual(r.assertions.releases, 1)
        XCTAssertEqual(r.tap.stopCount, 1)
    }

    func testStopWithoutASessionTouchesNothing() throws {
        let r = try rig(); defer { done(r) }
        r.cleaner.stop()
        XCTAssertEqual(r.assertions.releases, 0)
        XCTAssertEqual(r.tap.stopCount, 0)
        XCTAssertEqual(r.windows.hideCount, 0)
    }

    func testRemappedExitShortcutIsShownAndUsed() throws {
        let r = try rig(); defer { done(r) }
        let q = Shortcut(key: kVK_ANSI_Q, modifiers: Shortcut.control | Shortcut.shift)
        r.store.assign(q, to: ShortcutCommands.cleanerExit, among: ShortcutCommands.all)
        _ = r.cleaner.start()
        XCTAssertTrue(r.windows.shows.last?.contains("⌃⇧Q") == true)
        let f = try XCTUnwrap(r.tap.filter)
        XCTAssertEqual(f.verdict(for: CleanerEvent(kind: .keyDown, key: kVK_ANSI_Q, flags: [.maskControl, .maskShift])), .exit)
        XCTAssertEqual(f.verdict(for: CleanerEvent(kind: .keyDown, key: kVK_Escape, flags: [.maskControl, .maskAlternate, .maskCommand])), .swallow)
    }

    func testAClearedExitShortcutFallsBackToTheDefaultSoThereIsAlwaysAWayOut() throws {
        let r = try rig(); defer { done(r) }
        r.store.assign(nil, to: ShortcutCommands.cleanerExit, among: ShortcutCommands.all)
        _ = r.cleaner.start()
        XCTAssertTrue(r.windows.shows.last?.contains("⌃⌥⌘⎋") == true)
        let f = try XCTUnwrap(r.tap.filter)
        XCTAssertEqual(f.verdict(for: CleanerEvent(kind: .keyDown, key: kVK_Escape, flags: [.maskControl, .maskAlternate, .maskCommand])), .exit)
    }

    func testScreenChangeRebuildsWindowsWithoutASecondTap() throws {
        let r = try rig(); defer { done(r) }
        _ = r.cleaner.start()
        r.cleaner.screensChanged()
        XCTAssertEqual(r.windows.shows.count, 2)
        XCTAssertEqual(r.tap.startCount, 1)
    }

    func testScreenChangeWithoutASessionDoesNothing() throws {
        let r = try rig(); defer { done(r) }
        r.cleaner.screensChanged()
        XCTAssertTrue(r.windows.shows.isEmpty)
    }

    func testAccessibilityRevokedAtTickEndsTheSession() throws {
        let r = try rig(); defer { done(r) }
        _ = r.cleaner.start()
        r.cleaner.tick()
        XCTAssertTrue(r.cleaner.isActive, "still trusted: nothing happens")
        r.trust.value = false
        r.cleaner.tick()
        XCTAssertFalse(r.cleaner.isActive)
        XCTAssertFalse(r.windows.isShowing)
    }

    func testStartShortcutIsRegisteredOnlyWhileTheSettingIsOn() throws {
        let r = try rig(); defer { done(r) }
        XCTAssertNil(r.keybinds.command, "off by default: no standing key listener")
        r.settings.keyboardCleanerShortcutEnabled = true
        let registered = expectation(description: "registered")
        DispatchQueue.main.async { registered.fulfill() }
        wait(for: [registered], timeout: 2)
        XCTAssertEqual(r.keybinds.command, ShortcutCommands.cleanerStart)
        r.keybinds.handler?()
        XCTAssertTrue(r.cleaner.isActive, "the shortcut starts a session")
        r.cleaner.stop()
        r.settings.keyboardCleanerShortcutEnabled = false
        let unregistered = expectation(description: "unregistered")
        DispatchQueue.main.async { unregistered.fulfill() }
        wait(for: [unregistered], timeout: 2)
        XCTAssertNil(r.keybinds.command)
    }
}
