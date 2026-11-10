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
}
