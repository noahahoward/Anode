import XCTest
@testable import PowerKit

/// Anode's own Sound menu is a Beta Features setting, off until someone turns it on.
final class SoundMenuSettingsTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        (defaults, suiteName) = try TestDefaults.make(owner: "SoundMenuSettings", test: name)
    }

    override func tearDownWithError() throws {
        TestDefaults.destroy(defaults, suiteName)
    }

    func testDefaultIsOff() {
        XCTAssertFalse(Settings(defaults: defaults).soundMenuEnabled)
    }

    func testPersistsAcrossHandles() {
        Settings(defaults: defaults).soundMenuEnabled = true
        XCTAssertTrue(Settings(defaults: defaults).soundMenuEnabled)
    }

    func testNativeIconIsOffByDefaultAndPersists() {
        XCTAssertFalse(Settings(defaults: defaults).soundMenuUsesNativeIcon)
        Settings(defaults: defaults).soundMenuUsesNativeIcon = true
        XCTAssertTrue(Settings(defaults: defaults).soundMenuUsesNativeIcon)
    }

    func testChangeIsAnnouncedByKey() {
        let s = Settings(defaults: defaults)
        var heard = 0
        let token = s.observe(Settings.Key.soundMenuEnabled) { heard += 1 }
        s.soundMenuEnabled = true
        withExtendedLifetime(token) {}
        XCTAssertEqual(heard, 1)
    }
}
