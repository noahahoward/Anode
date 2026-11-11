import XCTest
@testable import PowerKit

/// The menu bar hider's three settings: on or off, how long the pill stays open, and which icons the owner arranged where.
final class MenuBarHiderSettingsTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        (defaults, suiteName) = try TestDefaults.make(owner: "MenuBarHiderSettings", test: name)
    }

    override func tearDownWithError() throws {
        TestDefaults.destroy(defaults, suiteName)
    }

    func testDefaults() {
        let s = Settings(defaults: defaults)
        XCTAssertFalse(s.menuBarHiderEnabled)
        XCTAssertEqual(s.menuBarHiderAutoCloseSeconds, 10)
        XCTAssertNil(s.menuBarHiderArrangement)
    }

    func testEnabledPersistsAcrossHandles() {
        Settings(defaults: defaults).menuBarHiderEnabled = true
        XCTAssertTrue(Settings(defaults: defaults).menuBarHiderEnabled)
    }

    func testAutoCloseAllowedValuesRoundTrip() {
        for seconds in [0, 5, 10, 30] {
            Settings(defaults: defaults).menuBarHiderAutoCloseSeconds = seconds
            XCTAssertEqual(Settings(defaults: defaults).menuBarHiderAutoCloseSeconds, seconds)
        }
    }

    func testUnknownAutoCloseReadsAsTen() {
        defaults.set(7, forKey: "anode." + Settings.Key.menuBarHiderAutoCloseSeconds)
        XCTAssertEqual(Settings(defaults: defaults).menuBarHiderAutoCloseSeconds, 10)
        Settings(defaults: defaults).menuBarHiderAutoCloseSeconds = 99
        XCTAssertEqual(Settings(defaults: defaults).menuBarHiderAutoCloseSeconds, 10)
    }

    func testArrangementRoundTripsAndGarbageReadsAsNil() {
        let a = BarArrangement(pinned: ["com.apple.controlcenter|Battery"], pillOrder: ["x|y", "z|w"])
        Settings(defaults: defaults).menuBarHiderArrangement = a
        XCTAssertEqual(Settings(defaults: defaults).menuBarHiderArrangement, a)
        defaults.set("not json", forKey: "anode." + Settings.Key.menuBarHiderArrangement)
        XCTAssertNil(Settings(defaults: defaults).menuBarHiderArrangement)
        Settings(defaults: defaults).menuBarHiderArrangement = nil
        XCTAssertNil(Settings(defaults: defaults).menuBarHiderArrangement)
    }

    func testChangeNotifiesOnce() {
        let s = Settings(defaults: defaults)
        var enabled = 0, close = 0, arrangement = 0
        let t1 = s.observe(Settings.Key.menuBarHiderEnabled) { enabled += 1 }
        let t2 = s.observe(Settings.Key.menuBarHiderAutoCloseSeconds) { close += 1 }
        let t3 = s.observe(Settings.Key.menuBarHiderArrangement) { arrangement += 1 }
        s.menuBarHiderEnabled = true
        s.menuBarHiderEnabled = true
        s.menuBarHiderAutoCloseSeconds = 30
        s.menuBarHiderAutoCloseSeconds = 30
        let a = BarArrangement(pinned: ["a|b"], pillOrder: [])
        s.menuBarHiderArrangement = a
        s.menuBarHiderArrangement = a
        XCTAssertEqual([enabled, close, arrangement], [1, 1, 1])
        _ = (t1, t2, t3)
    }
}
