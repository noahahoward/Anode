import XCTest
@testable import PowerKit

// The forecast assumes the load decays from what it is now toward what this
// machine usually draws: rate(t) = b + (c − b)·e^(−t/τ). These pin that it IS
// `timeToEmpty` wherever the two models must agree, and that the constant-power
// correction is applied exactly once.
final class LifetimeForecastTests: XCTestCase {

    private func forecast(_ charge: Double, c: Double, b: Double, tau: TimeInterval) -> TimeInterval? {
        DrainEstimate.forecastTimeToEmpty(chargePercent: charge, currentPctHr: c,
                                          baselinePctHr: b, tau: tau)
    }

    func testNoExcursionIsExactlyTimeToEmpty() {
        let expected = DrainEstimate.timeToEmpty(chargePercent: 70, ratePctHr: 12)
        XCTAssertEqual(forecast(70, c: 12, b: 12, tau: 600), expected)
    }

    func testAnExcursionThatNeverEndsIsTimeToEmptyAtTheCurrentRate() {
        let expected = DrainEstimate.timeToEmpty(chargePercent: 70, ratePctHr: 30)
        XCTAssertEqual(forecast(70, c: 30, b: 10, tau: .infinity), expected)
    }

    func testAnInstantExcursionIsTimeToEmptyAtTheBaseline() throws {
        let expected = try XCTUnwrap(DrainEstimate.timeToEmpty(chargePercent: 70, ratePctHr: 10))
        let t = try XCTUnwrap(forecast(70, c: 30, b: 10, tau: 1))
        XCTAssertEqual(t, expected, accuracy: expected * 1e-3)
    }

    /// The solved T must spend exactly the budget — charge scaled ONCE by the
    /// constant-power factor. Scaling it twice (or not at all) misses by ~2–7 %.
    func testTheSolvedTimeSpendsExactlyTheBudget() throws {
        let charge = 80.0, c = 25.0, b = 9.0, tau = 2400.0
        let t = try XCTUnwrap(forecast(charge, c: c, b: b, tau: tau))
        let th = t / 3600, tauh = tau / 3600
        let spent = b * th + (c - b) * tauh * (1 - exp(-th / tauh))
        let budget = charge * BatteryScale.constantPowerFactor(atSoCPercent: charge)
        XCTAssertEqual(spent, budget, accuracy: 1e-6)
    }

    func testAHeavyLoadThatWillFadeLandsBetweenTheTwoRates() throws {
        let t = try XCTUnwrap(forecast(60, c: 30, b: 10, tau: 1800))
        let atCurrent = try XCTUnwrap(DrainEstimate.timeToEmpty(chargePercent: 60, ratePctHr: 30))
        let atBaseline = try XCTUnwrap(DrainEstimate.timeToEmpty(chargePercent: 60, ratePctHr: 10))
        XCTAssertGreaterThan(t, atCurrent)
        XCTAssertLessThan(t, atBaseline)
    }

    /// Mean reversion works both ways: an idle moment below the usual draw is
    /// forecast to climb back toward it, not to last all day.
    func testAQuietMomentBelowBaselineIsNotTakenAsTheWholeDay() throws {
        let t = try XCTUnwrap(forecast(60, c: 3, b: 10, tau: 600))
        let atCurrent = try XCTUnwrap(DrainEstimate.timeToEmpty(chargePercent: 60, ratePctHr: 3))
        XCTAssertLessThan(t, atCurrent)
    }

    func testMoreLoadNowNeverMeansMoreTime() throws {
        var previous = TimeInterval.infinity
        for c in stride(from: 5.0, through: 60, by: 5) {
            let t = try XCTUnwrap(forecast(50, c: c, b: 10, tau: 1200))
            XCTAssertLessThanOrEqual(t, previous)
            previous = t
        }
    }

    func testRefusesWhatTimeToEmptyRefuses() {
        XCTAssertNil(forecast(0, c: 10, b: 10, tau: 600), "no charge")
        XCTAssertNil(forecast(50, c: 0.05, b: 0.05, tau: 600), "not meaningfully draining")
        XCTAssertNil(forecast(100, c: 0.2, b: 0.2, tau: 600), "past the 99 h cap")
        XCTAssertNil(forecast(50, c: .nan, b: 10, tau: 600))
    }

    // ── watts → %/hr at the live voltage ─────────────────────────────────────

    /// 1 W at 10 V is 0.1 A; on a 10 Ah pack that is 1 %/hr.
    func testWattsConvertAtTheLiveVoltage() {
        let scale = makeExactScale()
        XCTAssertEqual(scale.pctHrAtVoltage(watts: 1, voltage_mV: 10_000), 1, accuracy: 1e-12)
        // Same watts at a sagging voltage draws more current, so more %/hr.
        XCTAssertEqual(scale.pctHrAtVoltage(watts: 1, voltage_mV: 8_000), 1.25, accuracy: 1e-12)
    }
}
