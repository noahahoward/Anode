import XCTest
@testable import PowerKit

// The forecast check draws, beside the measured battery level, the level each
// prediction said it would be at. These pin that the two lines coincide when
// the prediction was right and part in the right direction when it was not.
final class ForecastCheckTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// A steady 10 %/hr discharge from 100 %, one sample a minute, with the app
    /// predicting `factor` times the true time left.
    private func discharge(minutes: Int, factor: Double) -> [ForecastCheck.Sample] {
        (0...minutes).map { m in
            let soc = 100 - 10 * Double(m) / 60
            let trueLeft = soc / 10 * 3600
            return .init(time: t0.addingTimeInterval(Double(m) * 60), socPercent: soc,
                         predictedSeconds: trueLeft * factor, shownPctHr: 10 / factor)
        }
    }

    func testARightForecastLandsOnTheActualLine() {
        let r = ForecastCheck.evaluate(discharge(minutes: 300, factor: 1),
                                       horizon: 3600, tolerance: 90)
        XCTAssertFalse(r.predictedLevel.isEmpty)
        let actual = Dictionary(uniqueKeysWithValues: r.actualLevel.map { ($0.time, $0.value) })
        for p in r.predictedLevel {
            XCTAssertEqual(p.value, actual[p.time]!, accuracy: 1e-9)
        }
        XCTAssertEqual(r.meanErrorPoints!, 0, accuracy: 1e-9)
        XCTAssertEqual(r.meanErrorFraction!, 0, accuracy: 1e-9)
    }

    /// Today's shape: the app said ~20 % less time than there was, so its
    /// line sits BELOW the measured one and both errors read negative.
    func testTooLittleTimeLeftReadsBelowAndNegative() {
        let r = ForecastCheck.evaluate(discharge(minutes: 300, factor: 0.8),
                                       horizon: 3600, tolerance: 90)
        XCTAssertLessThan(r.meanErrorPoints!, 0)
        XCTAssertEqual(r.meanErrorFraction!, -0.2, accuracy: 1e-9)
    }

    func testTooMuchTimeLeftReadsAboveAndPositive() {
        let r = ForecastCheck.evaluate(discharge(minutes: 300, factor: 1.25),
                                       horizon: 3600, tolerance: 90)
        XCTAssertGreaterThan(r.meanErrorPoints!, 0)
        XCTAssertEqual(r.meanErrorFraction!, 0.25, accuracy: 1e-9)
    }

    func testDrainIsTheLevelsOwnFall() {
        let r = ForecastCheck.evaluate(discharge(minutes: 120, factor: 1),
                                       horizon: 3600, tolerance: 90)
        XCTAssertFalse(r.actualDrain.isEmpty)
        for d in r.actualDrain { XCTAssertEqual(d.value, 10, accuracy: 1e-9) }
        for d in r.shownDrain { XCTAssertEqual(d.value, 10, accuracy: 1e-9) }
    }

    /// No stored prediction an hour back (a gap, or rows from before the column
    /// existed) draws nothing rather than borrowing a distant one.
    func testNothingIsDrawnAcrossAGap() {
        var s = discharge(minutes: 300, factor: 1)
        s.removeSubrange(0..<200)
        let r = ForecastCheck.evaluate(s, horizon: 3 * 3600, tolerance: 90)
        XCTAssertTrue(r.predictedLevel.isEmpty)
        XCTAssertNil(r.meanErrorPoints)
    }
}

// The forecast check reads the mAh-basis charge, not the integer macOS shows.
final class ForecastStoreTests: XCTestCase {

    private var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("forecast-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testFineChargeAndPredictionRoundTrip() throws {
        let s = try XCTUnwrap(HistoryStore(path: dir.appendingPathComponent("h.sqlite")))
        let t0 = Date().addingTimeInterval(-600)
        s.record(apps: [], measured_W: 8, attributed_W: nil, residual_W: nil,
                 onBattery: true, socPercent: 58, chargePercent: 57.34,
                 forecast: .init(predictedSeconds: 18_000, shownPctHr: 11.2),
                 interval: 2, at: t0)
        let p = try XCTUnwrap(s.forecastSeries(since: t0.addingTimeInterval(-1),
                                               until: t0.addingTimeInterval(1)).first)
        XCTAssertEqual(p.socPercent!, 57.34, accuracy: 1e-9)
        XCTAssertEqual(p.predictedSeconds!, 18_000, accuracy: 1e-9)
        XCTAssertEqual(p.shownPctHr!, 11.2, accuracy: 1e-9)
    }

    /// Rows from before the column existed fall back to the integer level.
    func testOlderRowsFallBackToTheIntegerLevel() throws {
        let s = try XCTUnwrap(HistoryStore(path: dir.appendingPathComponent("h.sqlite")))
        let t0 = Date().addingTimeInterval(-600)
        s.record(apps: [], measured_W: 8, attributed_W: nil, residual_W: nil,
                 onBattery: true, socPercent: 58, interval: 2, at: t0)
        let p = try XCTUnwrap(s.forecastSeries(since: t0.addingTimeInterval(-1),
                                               until: t0.addingTimeInterval(1)).first)
        XCTAssertEqual(p.socPercent!, 58, accuracy: 1e-9)
    }
}
