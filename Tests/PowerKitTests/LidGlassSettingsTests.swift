import XCTest
@testable import PowerKit

/// Lid Glass's three settings: the switch (off until asked for) and the two rates and angles the owner can move.
final class LidGlassSettingsTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        (defaults, suiteName) = try TestDefaults.make(owner: "LidGlassSettings", test: name)
    }

    override func tearDownWithError() throws {
        TestDefaults.destroy(defaults, suiteName)
    }

    func testDefaults() {
        let s = Settings(defaults: defaults)
        XCTAssertFalse(s.lidGlassEnabled)
        XCTAssertEqual(s.lidGlassIdleHz, 8)
        XCTAssertEqual(s.lidGlassTriggerAngle, 110)
    }

    func testIdleHzClampsTo4Through30() {
        let s = Settings(defaults: defaults)
        s.lidGlassIdleHz = 1;  XCTAssertEqual(s.lidGlassIdleHz, 4)
        s.lidGlassIdleHz = 99; XCTAssertEqual(s.lidGlassIdleHz, 30)
        s.lidGlassIdleHz = 12; XCTAssertEqual(s.lidGlassIdleHz, 12)
    }

    func testTriggerClampsTo60Through150() {
        let s = Settings(defaults: defaults)
        s.lidGlassTriggerAngle = 20;  XCTAssertEqual(s.lidGlassTriggerAngle, 60)
        s.lidGlassTriggerAngle = 200; XCTAssertEqual(s.lidGlassTriggerAngle, 150)
        s.lidGlassTriggerAngle = 95;  XCTAssertEqual(s.lidGlassTriggerAngle, 95)
    }

    func testChangesNotifyObserversOnlyWhenTheValueChanges() {
        let s = Settings(defaults: defaults)
        var fired = 0
        let token = s.observe(Settings.Key.lidGlassEnabled) { fired += 1 }
        s.lidGlassEnabled = true
        XCTAssertEqual(fired, 1)
        s.lidGlassEnabled = true
        XCTAssertEqual(fired, 1)
        s.lidGlassEnabled = false
        XCTAssertEqual(fired, 2)
        _ = token
    }

    func testValuesPersistAcrossHandles() {
        let s = Settings(defaults: defaults)
        s.lidGlassEnabled = true; s.lidGlassIdleHz = 20; s.lidGlassTriggerAngle = 100
        let again = Settings(defaults: defaults)
        XCTAssertTrue(again.lidGlassEnabled)
        XCTAssertEqual(again.lidGlassIdleHz, 20)
        XCTAssertEqual(again.lidGlassTriggerAngle, 100)
    }
}

/// Keep Awake's switch: off until asked for, and it tells observers only when it really changes.
final class KeepAwakeSettingsTests: XCTestCase {
    func testOffByDefaultAndNotifiesOnlyOnChange() throws {
        let (defaults, suite) = try TestDefaults.make(owner: "KeepAwakeSettings", test: name)
        defer { TestDefaults.destroy(defaults, suite) }
        let s = Settings(defaults: defaults)
        XCTAssertFalse(s.keepAwakeEnabled)
        var fired = 0
        let token = s.observe(Settings.Key.keepAwakeEnabled) { fired += 1 }
        s.keepAwakeEnabled = true; s.keepAwakeEnabled = true
        XCTAssertEqual(fired, 1)
        s.keepAwakeEnabled = false
        XCTAssertEqual(fired, 2)
        _ = token
    }
}
