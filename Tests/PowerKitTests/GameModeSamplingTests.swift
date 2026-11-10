import XCTest
@testable import AnodeApp
@testable import PowerKit

/// What the sampler does while the strip is up: more readings, and the user's tick rate instead of the hidden one.
final class GameModeSamplingTests: XCTestCase {

    func testNeedsAddedOnlyWhileAGameShows() {
        let on = AppDelegate.samplingNeeds(base: [], gameShowing: true)
        XCTAssertTrue(on.isSuperset(of: [.cpu, .memory, .gpu, .sensors]))
        XCTAssertEqual(AppDelegate.samplingNeeds(base: [.network], gameShowing: false), [.network])
        XCTAssertTrue(AppDelegate.samplingNeeds(base: [.network], gameShowing: true).contains(.network))
    }

    func testHiddenRateDoesNotApplyWhileTheStripIsUp() {
        XCTAssertFalse(AppDelegate.tickIsHidden(visible: false, panelOpen: false, gameShowing: true))
        XCTAssertTrue(AppDelegate.tickIsHidden(visible: false, panelOpen: false, gameShowing: false))
        XCTAssertFalse(AppDelegate.tickIsHidden(visible: true, panelOpen: false, gameShowing: false))
        XCTAssertFalse(AppDelegate.tickIsHidden(visible: true, panelOpen: false, gameShowing: true))
    }

    func testCadenceAtTheUsersSettingWhileShowing() {
        let hidden = AppDelegate.tickIsHidden(visible: false, panelOpen: false, gameShowing: true)
        XCTAssertEqual(AppDelegate.cadence(hidden: hidden, setting: 2, drivingFans: false), 2)
        let still = AppDelegate.tickIsHidden(visible: false, panelOpen: false, gameShowing: false)
        XCTAssertEqual(AppDelegate.cadence(hidden: still, setting: 2, drivingFans: false), AppDelegate.hiddenInterval)
    }
}
