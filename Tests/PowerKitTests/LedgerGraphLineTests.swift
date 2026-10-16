import XCTest
@testable import PowerKit
@testable import AnodeApp

/// The ledger graph's selectable lines: what is stored, and what gets drawn.
final class LedgerGraphLineTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var settings: Settings!

    override func setUpWithError() throws {
        let made = try TestDefaults.make(owner: "LedgerGraphLine", test: name)
        defaults = made.defaults
        suiteName = made.name
        settings = Settings(defaults: defaults)
    }

    override func tearDownWithError() throws {
        settings = nil
        TestDefaults.destroy(defaults, suiteName)
    }

    private func pts(_ values: [Double]) -> [HistoryGraphView.Point] {
        values.enumerated().map { .init(time: Date(timeIntervalSince1970: Double($0.offset) * 60),
                                        value: $0.element) }
    }

    /// Never set is the graph as it was before it could be changed.
    func testUntouchedSettingsAreTheOriginalGraph() {
        XCTAssertEqual(settings.ledgerGraphLines, ["graph.drain", "graph.mean", "battery.percent"])
    }

    /// An empty list is an answer — "draw nothing" — and must not read as "never
    /// asked", or unticking the last box would put the defaults back.
    func testUntickingEverythingStaysUnticked() {
        settings.ledgerGraphLines = []
        XCTAssertEqual(settings.ledgerGraphLines, [])
        XCTAssertEqual(Settings(defaults: defaults).ledgerGraphLines, [])
    }

    func testUnknownIDsSurviveARoundTrip() {
        settings.ledgerGraphLines = ["graph.drain", "from.a.newer.build"]
        XCTAssertEqual(settings.ledgerGraphLines, ["graph.drain", "from.a.newer.build"])
    }

    func testDefaultsDrawDrainMeanAndBatteryExactlyAsBefore() {
        let drawn = LedgerGraphLine.build(
            selected: [.drain, .mean, .battery],
            drain: pts([5, 6, 7]), mean: pts([6, 6]),
            charge: pts([90, 89, 88]), extras: [:], drainFilled: true)
        XCTAssertEqual(drawn.series.map(\.name), ["%/hr", AppDelegate.drainTrendSeriesName])
        XCTAssertEqual(drawn.right?.name, "battery")
        XCTAssertEqual(drawn.axisLabel, "%/hr")
        XCTAssertEqual(drawn.rightAxisLabel, "battery")
    }

    func testExtraPercentLinesJoinTheLeftAxis() {
        let drawn = LedgerGraphLine.build(
            selected: [.drain, .cpu, .battery],
            drain: pts([5, 6]), mean: [], charge: pts([90, 89]),
            extras: [.cpu: pts([10, 20])], drainFilled: false)
        XCTAssertEqual(drawn.series.map(\.name), ["%/hr", "cpu"])
        XCTAssertEqual(drawn.axisLabel, "%/hr \u{00B7} %")
    }

    func testBatteryOffDropsTheRightSeriesAndEverythingOffDrawsNothing() {
        let noBattery = LedgerGraphLine.build(
            selected: [.drain], drain: pts([5, 6]), mean: [], charge: pts([90, 89]),
            extras: [:], drainFilled: true)
        XCTAssertNil(noBattery.right)
        XCTAssertEqual(noBattery.rightAxisLabel, "")

        let none = LedgerGraphLine.build(
            selected: [], drain: pts([5, 6]), mean: pts([5, 5]), charge: pts([90, 89]),
            extras: [.cpu: pts([1, 2])], drainFilled: true)
        XCTAssertTrue(none.series.isEmpty)
        XCTAssertNil(none.right)
    }

    /// A selected line with no data is left out rather than drawn as a flat zero.
    func testASelectedLineWithNoPointsIsNotDrawn() {
        let drawn = LedgerGraphLine.build(
            selected: [.fan], drain: [], mean: [], charge: [], extras: [.fan: []],
            drainFilled: false)
        XCTAssertTrue(drawn.series.isEmpty)
    }

    func testPercentPointsSayPercentOnHover() {
        XCTAssertEqual(LedgerGraphLine.percentPoint(Date(), 42.37).detail, "42%")
    }
}
