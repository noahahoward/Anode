import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// The Game Mode controller with the strip, the workspace observer, the frontmost app and the readings all faked: nothing
/// here shows a real window or reads the real frontmost app.
final class GameModeControllerTests: XCTestCase {

    final class FakePresenter: GameHUDPresenting {
        var shows: [(text: String, frame: CGRect)] = []
        var hideCount = 0
        private(set) var isShowing = false
        func size(for text: String) -> CGSize { CGSize(width: CGFloat(text.count) * 7, height: 22) }
        func show(text: String, frame: CGRect) { shows.append((text, frame)); isShowing = true }
        func hide() { hideCount += 1; isShowing = false }
    }

    final class FakeObserver: ActivationObserving {
        var starts = 0, stops = 0
        func start(_ onChange: @escaping () -> Void) { starts += 1 }
        func stop() { stops += 1 }
    }

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var settings: Settings!
    private let presenter = FakePresenter()
    private let observer = FakeObserver()
    private var app: FrontmostApp?
    private var frontmostCalls = 0
    private var readings: [MetricID: MetricValue] = [:]
    private var clock = Date(timeIntervalSince1970: 1_000_000)
    private var controller: GameModeController!

    private let game = FrontmostApp(bundleID: "com.x.game", category: "public.app-category.games", fullscreen: true,
                                    screenFrame: CGRect(x: 0, y: 0, width: 1800, height: 1169), safeTop: 39, menuBarHeight: 39)
    private let utility = FrontmostApp(bundleID: "com.x.tool", category: "public.app-category.utilities", fullscreen: false,
                                       screenFrame: CGRect(x: 0, y: 0, width: 1800, height: 1169), safeTop: 39, menuBarHeight: 39)

    override func setUpWithError() throws {
        (defaults, suiteName) = try TestDefaults.make(owner: "GameModeController", test: name)
        settings = Settings(defaults: defaults)
        readings = [.cpuTemperature: MetricValue(value: 62, text: "62°", isEstimate: false),
                    .cpuUsage: MetricValue(value: 41, text: "41%", isEstimate: false)]
    }

    override func tearDownWithError() throws {
        controller?.shutdown()
        controller = nil
        TestDefaults.destroy(defaults, suiteName)
    }

    private func makeController() {
        controller = GameModeController(settings: settings, presenter: presenter, observer: observer,
                                        frontmost: { [unowned self] in frontmostCalls += 1; return app },
                                        value: { [unowned self] in readings[$0] },
                                        now: { [unowned self] in clock })
    }

    /// Settings changes reach the controller through the main queue, as the cleaner's do.
    private func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

    private var expectedText: String { GameHUDText.line { self.readings[$0] } }

    func testNothingExistsWhileDisabled() {
        app = game
        makeController()
        XCTAssertEqual(observer.starts, 0)
        XCTAssertTrue(presenter.shows.isEmpty)
        XCTAssertFalse(controller.isShowing)
        XCTAssertEqual(controller.needs, [])
    }

    func testEnablingStartsTheObserverAndAGameShowsTheStrip() {
        app = game
        makeController()
        settings.gameHUDEnabled = true
        pump()
        XCTAssertEqual(observer.starts, 1)
        XCTAssertEqual(presenter.shows.count, 1)
        XCTAssertEqual(presenter.shows.first?.text, expectedText)
        XCTAssertTrue(controller.isShowing)
        XCTAssertTrue(controller.needs.contains(.sensors))
        XCTAssertTrue(controller.needs.isSuperset(of: [.cpu, .memory, .gpu]))
    }

    func testNonGameShowsNothing() {
        settings.gameHUDEnabled = true
        app = utility
        makeController()
        XCTAssertTrue(presenter.shows.isEmpty)
        XCTAssertEqual(presenter.hideCount, 0)
        XCTAssertEqual(controller.needs, [])
    }

    func testGameLosingFocusHidesAndDropsNeeds() {
        settings.gameHUDEnabled = true
        app = game
        makeController()
        XCTAssertTrue(controller.isShowing)
        app = utility
        controller.reevaluate()
        XCTAssertEqual(presenter.hideCount, 1)
        XCTAssertFalse(controller.isShowing)
        XCTAssertEqual(controller.needs, [])
    }

    func testDisablingWhileShowingHidesAndStopsTheObserver() {
        settings.gameHUDEnabled = true
        app = game
        makeController()
        settings.gameHUDEnabled = false
        pump()
        XCTAssertEqual(presenter.hideCount, 1)
        XCTAssertEqual(observer.stops, 1)
        XCTAssertEqual(controller.needs, [])
    }

    func testExtraAppCountsAsGame() {
        settings.gameHUDEnabled = true
        settings.gameHUDExtraApps = ["com.x.tool"]
        app = utility
        makeController()
        XCTAssertTrue(controller.isShowing)
    }

    func testNoFrontmostAppIsNotAGame() {
        settings.gameHUDEnabled = true
        app = nil
        makeController()
        XCTAssertFalse(controller.isShowing)
        XCTAssertTrue(presenter.shows.isEmpty)
    }

    func testRefreshUpdatesTheTextWithoutRestartingAnything() {
        settings.gameHUDEnabled = true
        app = game
        makeController()
        readings[.cpuTemperature] = MetricValue(value: 75, text: "75°", isEstimate: false)
        controller.refresh()
        XCTAssertEqual(presenter.shows.count, 2)
        XCTAssertEqual(presenter.shows.last?.text, expectedText)
        XCTAssertTrue(presenter.shows.last?.text.contains("75°") ?? false)
        XCTAssertEqual(observer.starts, 1)
    }

    func testRefreshWhenNotShowingDoesNothing() {
        settings.gameHUDEnabled = true
        app = utility
        makeController()
        let calls = frontmostCalls
        controller.refresh()
        XCTAssertEqual(frontmostCalls, calls)
        XCTAssertTrue(presenter.shows.isEmpty)
    }

    func testPreviewShowsForFiveSecondsWithoutAGame() {
        app = utility
        makeController()
        controller.preview()
        XCTAssertTrue(controller.isShowing)
        XCTAssertEqual(presenter.shows.count, 1)
        clock = clock.addingTimeInterval(4)
        controller.refresh()
        XCTAssertTrue(controller.isShowing)
        clock = clock.addingTimeInterval(2)
        controller.refresh()
        XCTAssertFalse(controller.isShowing)
        XCTAssertEqual(presenter.hideCount, 1)
        XCTAssertEqual(controller.needs, [])
    }

    func testFrameComesFromPlacement() {
        settings.gameHUDEnabled = true
        settings.gameHUDCorner = .bottomLeft
        app = game
        makeController()
        let size = presenter.size(for: expectedText)
        let expected = GameHUDPlacement.frame(size: size, corner: .bottomLeft, screenFrame: game.screenFrame,
                                              safeTop: 39, menuBarHeight: 39, fullscreen: true)
        XCTAssertEqual(presenter.shows.last?.frame, expected)
    }

    func testChangingTheCornerMovesTheStrip() {
        settings.gameHUDEnabled = true
        app = game
        makeController()
        let before = presenter.shows.last?.frame
        settings.gameHUDCorner = .topLeft
        pump()
        XCTAssertNotEqual(presenter.shows.last?.frame, before)
        XCTAssertEqual(presenter.shows.last?.frame.origin.x, 8)
    }

    func testShutdownHidesAndStops() {
        settings.gameHUDEnabled = true
        app = game
        makeController()
        controller.shutdown()
        XCTAssertEqual(presenter.hideCount, 1)
        XCTAssertEqual(observer.stops, 1)
        XCTAssertFalse(controller.isShowing)
    }

    func testOnChangeFiresOnShowAndHideOnly() {
        settings.gameHUDEnabled = true
        app = game
        var changes = 0
        makeController()
        controller.onChange = { changes += 1 }
        controller.refresh()
        controller.refresh()
        XCTAssertEqual(changes, 0)
        app = utility
        controller.reevaluate()
        XCTAssertEqual(changes, 1)
    }
}
