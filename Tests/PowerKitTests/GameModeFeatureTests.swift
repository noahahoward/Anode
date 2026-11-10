import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// The Game Mode section of Beta Features drives the setting and the controller the way a click would.
final class GameModeFeatureTests: XCTestCase {

    private struct Rig {
        let feature: GameModeFeature
        let controller: GameModeController
        let presenter: GameModeControllerTests.FakePresenter
        let settings: Settings
        let defaults: UserDefaults
        let suite: String
    }

    private let utility = FrontmostApp(bundleID: "com.x.tool", category: "public.app-category.utilities", fullscreen: false,
                                       screenFrame: CGRect(x: 0, y: 0, width: 1800, height: 1169), safeTop: 39, menuBarHeight: 39)

    private func rig() throws -> Rig {
        let (defaults, suite) = try TestDefaults.make(owner: "GameModeUI", test: name)
        let settings = Settings(defaults: defaults)
        let presenter = GameModeControllerTests.FakePresenter()
        let app = utility
        let controller = GameModeController(settings: settings, presenter: presenter,
                                            observer: GameModeControllerTests.FakeObserver(),
                                            frontmost: { app }, value: { _ in nil }, log: { _ in })
        let feature = GameModeFeature(settings: settings, controller: { controller },
                                      displayName: { "App \($0)" })
        _ = feature.makeView()
        return Rig(feature: feature, controller: controller, presenter: presenter, settings: settings,
                   defaults: defaults, suite: suite)
    }

    private func done(_ r: Rig) { r.controller.shutdown(); TestDefaults.destroy(r.defaults, r.suite) }

    func testCheckboxWritesTheSetting() throws {
        let r = try rig(); defer { done(r) }
        XCTAssertEqual(r.feature.enableCheckbox.state, .off)
        r.feature.enableCheckbox.performClick(nil)
        XCTAssertTrue(r.settings.gameHUDEnabled)
        r.feature.enableCheckbox.performClick(nil)
        XCTAssertFalse(r.settings.gameHUDEnabled)
    }

    func testCornerPopupWritesTheSettingAndStartsOnTheStoredCorner() throws {
        let r = try rig(); defer { done(r) }
        XCTAssertEqual(r.feature.cornerPopup.itemTitles, ["Top right", "Top left", "Bottom right", "Bottom left"])
        XCTAssertEqual(r.feature.cornerPopup.indexOfSelectedItem, 0)
        r.settings.gameHUDCorner = .bottomRight
        r.feature.refresh()
        XCTAssertEqual(r.feature.cornerPopup.indexOfSelectedItem, 2)
        r.feature.cornerPopup.selectItem(at: 1)
        // performClick would open the popup's menu and wait for a human; send the action it would send.
        NSApp.sendAction(r.feature.cornerPopup.action!, to: r.feature.cornerPopup.target, from: r.feature.cornerPopup)
        XCTAssertEqual(r.settings.gameHUDCorner, .topLeft)
    }

    func testPreviewButtonCallsTheController() throws {
        let r = try rig(); defer { done(r) }
        r.feature.previewButton.performClick(nil)
        XCTAssertEqual(r.presenter.shows.count, 1)
        XCTAssertTrue(r.controller.isShowing)
    }

    func testAddAndRemoveChangeExtraApps() throws {
        let r = try rig(); defer { done(r) }
        r.feature.add(bundleID: "com.x.one")
        r.feature.add(bundleID: "com.x.two")
        r.feature.add(bundleID: "com.x.one")   // already there
        XCTAssertEqual(r.settings.gameHUDExtraApps, ["com.x.one", "com.x.two"])
        XCTAssertEqual(r.feature.appsList.itemTitles, ["App com.x.one", "App com.x.two"])
        r.feature.appsList.selectItem(at: 0)
        r.feature.removeSelected()
        XCTAssertEqual(r.settings.gameHUDExtraApps, ["com.x.two"])
        XCTAssertEqual(r.feature.appsList.itemTitles, ["App com.x.two"])
        r.feature.removeSelected()
        XCTAssertEqual(r.settings.gameHUDExtraApps, [])
        XCTAssertFalse(r.feature.removeButton.isEnabled)
        r.feature.removeSelected()   // nothing to remove is not an error
        XCTAssertEqual(r.settings.gameHUDExtraApps, [])
    }

    func testRefreshReflectsStoredState() throws {
        let r = try rig(); defer { done(r) }
        r.settings.gameHUDEnabled = true
        r.settings.gameHUDExtraApps = ["com.x.three"]
        r.feature.refresh()
        XCTAssertEqual(r.feature.enableCheckbox.state, .on)
        XCTAssertEqual(r.feature.appsList.itemTitles, ["App com.x.three"])
        XCTAssertTrue(r.feature.removeButton.isEnabled)
    }

    func testHotCornerCheckboxWritesTheSettingAndRefreshReflectsIt() throws {
        let r = try rig(); defer { done(r) }
        XCTAssertEqual(r.feature.hotCornerCheckbox.state, .off)
        r.feature.hotCornerCheckbox.performClick(nil)
        XCTAssertTrue(r.settings.gameHUDHotCorner)
        r.settings.gameHUDHotCorner = false
        r.feature.refresh()
        XCTAssertEqual(r.feature.hotCornerCheckbox.state, .off)
    }

    func testHotCornerCopyWarnsThatTheCornerPixelsStopReceivingClicks() throws {
        let r = try rig(); defer { done(r) }
        XCTAssertTrue(r.feature.hotCornerNote.stringValue.lowercased().contains("click"), r.feature.hotCornerNote.stringValue)
    }

    func testSectionIsInTheWindowsList() {
        XCTAssertTrue(BetaFeaturesWindowController().features.contains { $0 is GameModeFeature })
    }
}
