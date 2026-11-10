import XCTest
@testable import PowerKit

/// The Game Mode HUD's three settings: whether it runs, which corner it sits in, and the apps the owner added by hand.
final class GameModeSettingsTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        (defaults, suiteName) = try TestDefaults.make(owner: "GameModeSettings", test: name)
    }

    override func tearDownWithError() throws {
        TestDefaults.destroy(defaults, suiteName)
    }

    func testDefaults() {
        let s = Settings(defaults: defaults)
        XCTAssertFalse(s.gameHUDEnabled)
        XCTAssertEqual(s.gameHUDCorner, .topRight)
        XCTAssertEqual(s.gameHUDExtraApps, [])
    }

    func testEnabledPersistsAcrossHandles() {
        Settings(defaults: defaults).gameHUDEnabled = true
        XCTAssertTrue(Settings(defaults: defaults).gameHUDEnabled)
    }

    func testCornerRoundTrips() {
        for corner in HUDCorner.allCases {
            Settings(defaults: defaults).gameHUDCorner = corner
            XCTAssertEqual(Settings(defaults: defaults).gameHUDCorner, corner)
        }
    }

    func testUnknownCornerReadsAsTopRight() {
        defaults.set("middleOfNowhere", forKey: "anode." + Settings.Key.gameHUDCorner)
        XCTAssertEqual(Settings(defaults: defaults).gameHUDCorner, .topRight)
    }

    func testExtraAppsDedupedAndCleaned() {
        let s = Settings(defaults: defaults)
        s.gameHUDExtraApps = ["a", "b", "a", ""]
        XCTAssertEqual(s.gameHUDExtraApps, ["a", "b"])
        XCTAssertEqual(Settings(defaults: defaults).gameHUDExtraApps, ["a", "b"])
    }

    func testChangeNotifiesObservers() {
        let s = Settings(defaults: defaults)
        var enabled = 0, corner = 0, apps = 0
        let t1 = s.observe(Settings.Key.gameHUDEnabled) { enabled += 1 }
        let t2 = s.observe(Settings.Key.gameHUDCorner) { corner += 1 }
        let t3 = s.observe(Settings.Key.gameHUDExtraApps) { apps += 1 }
        s.gameHUDEnabled = true
        s.gameHUDCorner = .bottomLeft
        s.gameHUDExtraApps = ["com.x.y"]
        XCTAssertEqual([enabled, corner, apps], [1, 1, 1])
        // The same value again tells nobody anything.
        s.gameHUDEnabled = true
        s.gameHUDCorner = .bottomLeft
        s.gameHUDExtraApps = ["com.x.y"]
        XCTAssertEqual([enabled, corner, apps], [1, 1, 1])
        _ = (t1, t2, t3)
    }

    func testHotCornerDefaultsOffPersistsAndNotifies() {
        let s = Settings(defaults: defaults)
        XCTAssertFalse(s.gameHUDHotCorner)
        var fired = 0
        let token = s.observe(Settings.Key.gameHUDHotCorner) { fired += 1 }
        s.gameHUDHotCorner = true
        s.gameHUDHotCorner = true
        XCTAssertEqual(fired, 1)
        XCTAssertTrue(Settings(defaults: defaults).gameHUDHotCorner)
        _ = token
    }
}
