import XCTest
@testable import PowerKit

/// The keyboard cleaner's one setting: whether its start shortcut is listened for. Off until asked for.
final class CleanerSettingsTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        (defaults, suiteName) = try TestDefaults.make(owner: "CleanerSettings", test: name)
    }

    override func tearDownWithError() throws {
        TestDefaults.destroy(defaults, suiteName)
    }

    func testDefaultIsOff() {
        XCTAssertFalse(Settings(defaults: defaults).keyboardCleanerShortcutEnabled)
    }

    func testValuePersistsAcrossHandles() {
        Settings(defaults: defaults).keyboardCleanerShortcutEnabled = true
        XCTAssertTrue(Settings(defaults: defaults).keyboardCleanerShortcutEnabled)
    }

    func testChangesNotifyObserversOnlyWhenTheValueChanges() {
        let s = Settings(defaults: defaults)
        var fired = 0
        let token = s.observe(Settings.Key.keyboardCleanerShortcutEnabled) { fired += 1 }
        s.keyboardCleanerShortcutEnabled = true
        XCTAssertEqual(fired, 1)
        s.keyboardCleanerShortcutEnabled = true
        XCTAssertEqual(fired, 1)
        s.keyboardCleanerShortcutEnabled = false
        XCTAssertEqual(fired, 2)
        _ = token
    }
}
