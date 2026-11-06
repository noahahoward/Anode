import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// The Beta Features section drives the cleaner the way a click would.
final class KeyboardCleanerFeatureTests: XCTestCase {

    private struct Rig {
        let feature: KeyboardCleanerFeature
        let cleaner: KeyboardCleaner
        let tap: KeyboardCleanerTests.FakeTap
        let settings: Settings
        let trust: KeyboardCleanerTests.Box<Bool>
        let requests: KeyboardCleanerTests.Box<Int>
        let defaults: UserDefaults
        let suite: String
    }

    private func rig(trusted: Bool = true) throws -> Rig {
        let (defaults, suite) = try TestDefaults.make(owner: "KeyboardCleanerUI", test: name)
        let settings = Settings(defaults: defaults)
        let store = ShortcutStore(defaults: defaults)
        let tap = KeyboardCleanerTests.FakeTap()
        let trust = KeyboardCleanerTests.Box(trusted)
        let requests = KeyboardCleanerTests.Box(0)
        let cleaner = KeyboardCleaner(settings: settings, store: store, tap: tap, windows: KeyboardCleanerTests.FakeWindows(),
                                      assertions: KeyboardCleanerTests.FakeAssertions(), keybinds: KeyboardCleanerTests.FakeKeybinds(),
                                      isTrusted: { trust.value }, screens: { [] }, keysDown: { [] })
        cleaner.log = { _ in }
        let feature = KeyboardCleanerFeature(settings: settings, store: store, cleaner: { cleaner },
                                             accessibilityAllowed: { trust.value },
                                             requestAccessibility: { requests.value += 1 })
        _ = feature.makeView()
        return Rig(feature: feature, cleaner: cleaner, tap: tap, settings: settings, trust: trust, requests: requests,
                   defaults: defaults, suite: suite)
    }

    private func done(_ r: Rig) { r.cleaner.stop(); TestDefaults.destroy(r.defaults, r.suite) }

    func testStartButtonStartsASession() throws {
        let r = try rig(); defer { done(r) }
        r.feature.startButton.performClick(nil)
        XCTAssertTrue(r.cleaner.isActive)
        XCTAssertEqual(r.tap.startCount, 1)
    }

    func testWithoutAccessibilityStartAsksAndDoesNotStart() throws {
        let r = try rig(trusted: false); defer { done(r) }
        XCTAssertFalse(r.feature.accessButton.isHidden, "the button to open Accessibility settings is shown")
        XCTAssertTrue(r.feature.statusLabel.stringValue.contains("Accessibility"))
        r.feature.startButton.performClick(nil)
        XCTAssertFalse(r.cleaner.isActive)
        XCTAssertEqual(r.tap.startCount, 0)
        XCTAssertEqual(r.requests.value, 1, "the system's question is put once")
    }

    func testWithAccessibilityTheAccessButtonIsHidden() throws {
        let r = try rig(); defer { done(r) }
        XCTAssertTrue(r.feature.accessButton.isHidden)
    }

    func testTheShortcutCheckboxWritesTheSetting() throws {
        let r = try rig(); defer { done(r) }
        XCTAssertEqual(r.feature.shortcutCheckbox.state, .off)
        r.feature.shortcutCheckbox.performClick(nil)
        XCTAssertTrue(r.settings.keyboardCleanerShortcutEnabled)
        r.feature.shortcutCheckbox.performClick(nil)
        XCTAssertFalse(r.settings.keyboardCleanerShortcutEnabled)
    }

    func testTheSectionNamesBothShortcuts() throws {
        let r = try rig(); defer { done(r) }
        XCTAssertTrue(r.feature.shortcutCheckbox.title.contains("⌃⌥⌘K"))
        XCTAssertTrue(r.feature.exitNote.stringValue.contains("⌃⌥⌘⎋"))
    }

    func testDuringASessionTheButtonIsDisabledSoItCannotBePressedTwice() throws {
        let r = try rig(); defer { done(r) }
        r.feature.startButton.performClick(nil)
        r.feature.refresh()
        XCTAssertFalse(r.feature.startButton.isEnabled)
        r.cleaner.stop()
        r.feature.refresh()
        XCTAssertTrue(r.feature.startButton.isEnabled)
    }
}
