import XCTest
@testable import PowerKit

/// What counts as a game: an app in macOS's Games category, or one the owner added by hand.
final class GameRulesTests: XCTestCase {

    func testGamesCategoriesMatch() {
        XCTAssertTrue(GameRules.isGameCategory("public.app-category.games"))
        XCTAssertTrue(GameRules.isGameCategory("public.app-category.simulation-games"))
        XCTAssertTrue(GameRules.isGameCategory("public.app-category.action-games"))
    }

    func testOtherCategoriesDoNot() {
        XCTAssertFalse(GameRules.isGameCategory("public.app-category.utilities"))
        XCTAssertFalse(GameRules.isGameCategory(nil))
        XCTAssertFalse(GameRules.isGameCategory(""))
    }

    func testExtraAppsCountAsGames() {
        XCTAssertTrue(GameRules.isGame(bundleID: "com.x.y", category: nil, extraApps: ["com.x.y"]))
    }

    func testNilBundleIDWithNoCategoryIsNotAGame() {
        XCTAssertFalse(GameRules.isGame(bundleID: nil, category: nil, extraApps: ["com.x.y"]))
    }

    func testExtraAppMatchIsExact() {
        XCTAssertFalse(GameRules.isGame(bundleID: "com.x.yy", category: nil, extraApps: ["com.x.y"]))
    }

    func testCategoryAloneMakesAGame() {
        XCTAssertTrue(GameRules.isGame(bundleID: "com.x.y", category: "public.app-category.games", extraApps: []))
    }

    /// Measured on 2026-11-09 with the notification `com.apple.system.game_mode_status_changed`: 1 with Bloons TD6 in front,
    /// 2 with a browser in front. Anything else is "not on".
    func testAppleGameModeStateMapping() {
        XCTAssertEqual(AppleGameMode.notificationName, "com.apple.system.game_mode_status_changed")
        XCTAssertTrue(AppleGameMode.isOn(state: 1))
        XCTAssertFalse(AppleGameMode.isOn(state: 0))
        XCTAssertFalse(AppleGameMode.isOn(state: 2))
        XCTAssertFalse(AppleGameMode.isOn(state: 99))
    }
}
