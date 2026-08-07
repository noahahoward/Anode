import XCTest
@testable import PowerKit

/// The gas-gauge delta maths. The two documented traps: (1) only accumulator DELTAS
/// mean anything — the cumulative ratio is a lifetime average; (2) counters wrap
/// (AdapterEfficiencyLoss observed at 2^64−119 live), so subtraction must be
/// wrapping, never trapping.
final class SystemPowerWindowTests: XCTestCase {

    private func telemetry(load: UInt64, count: UInt64, at t: TimeInterval) -> PowerTelemetry {
        PowerTelemetry(accumulatedSystemLoad: load,
                       accumulatorCount: count,
                       systemLoad_mW: 0,
                       timestamp: Date(timeIntervalSinceReferenceDate: t))
    }

    func testDeltaRatioIsMeanPowerOverTheWindow() {
        let a = telemetry(load: 100_000, count: 100, at: 0)
        let b = telemetry(load: 460_000, count: 160, at: 60)
        let w = SystemPowerWindow.between(a, b)
        XCTAssertNotNil(w)
        XCTAssertEqual(w!.power_mW, 6000.0)          // 360,000 mW·ticks / 60 ticks
        XCTAssertEqual(w!.ticks, 60)
        XCTAssertEqual(w!.span, 60.0, accuracy: 1e-9)
    }

    /// No new batch published → the correct answer is "not yet known", never a
    /// number derived from wall-clock division (that was the 4.8→10.08→5.0 swing).
    func testNoNewBatchReturnsNil() {
        let a = telemetry(load: 100_000, count: 100, at: 0)
        let b = telemetry(load: 100_000, count: 100, at: 45)
        XCTAssertNil(SystemPowerWindow.between(a, b))
    }

    /// Load accumulator wraps through 2^64: the wrapping delta must still be the
    /// true energy, not a trap and not a garbage near-2^64 figure fed to Double.
    func testLoadCounterWrapUsesWrappingArithmetic() {
        let a = telemetry(load: UInt64.max - 299_999, count: 100, at: 0)
        let b = telemetry(load: 60_001, count: 160, at: 60)
        let w = SystemPowerWindow.between(a, b)
        XCTAssertNotNil(w)
        // True delta across the wrap: 300,000 + 60,001 = 360,001 over 60 ticks.
        XCTAssertEqual(w!.power_mW, 360_001.0 / 60.0, accuracy: 1e-9)
        XCTAssertLessThan(w!.power_mW, 1e6, "a wrapped counter must not explode the mean")
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// Regression tests for the counter-reset bug that poisoned the history store.
///
/// Four stored buckets held energies around 1.8e16 J — one of them 2^63 scaled —
/// because a DECREASE in the accumulator was treated as a 2^64 wrap by `&-`.
/// Divided by 60 ticks that is ~3e14 W, and a single such row dominates every SUM
/// it lands in. The graph read 1e+15 %/hr before anyone noticed.
final class SystemPowerWindowResetTests: XCTestCase {

    private func telemetry(load: UInt64, count: UInt64,
                           at t: TimeInterval) -> PowerTelemetry {
        PowerTelemetry(accumulatedSystemLoad: load, accumulatorCount: count,
                       systemLoad_mW: 0, timestamp: Date(timeIntervalSince1970: t))
    }

    func testNormalWindowIsTheMeanOverTheTicks() {
        let a = telemetry(load: 100_000, count: 1000, at: 0)
        let b = telemetry(load: 400_000, count: 1060, at: 60)
        let w = SystemPowerWindow.between(a, b)
        XCTAssertEqual(w?.power_mW ?? 0, 5000, accuracy: 1e-9)
        XCTAssertEqual(w?.ticks, 60)
    }

    /// The actual bug. A reset must yield NO window rather than a wrapped one.
    /// Note this coexists with testLoadCounterWrapUsesWrappingArithmetic above: a
    /// genuine wrap leaves a small delta and is kept, a reset leaves a near-2^64
    /// delta and is rejected. Plausibility separates them; the sign does not.
    func testAccumulatorResetYieldsNoWindowInsteadOfAstronomicalPower() {
        let a = telemetry(load: 5_000_000, count: 1000, at: 0)
        let b = telemetry(load: 1_200, count: 1060, at: 60)   // reset to near zero
        XCTAssertNil(SystemPowerWindow.between(a, b),
                     "a counter reset must not be reported as ~3e14 W")
    }

    /// Guards the exact shape that reached the disk.
    func testWrappedSubtractionCannotProduceAStorableNumber() {
        let a = telemetry(load: UInt64.max / 2, count: 1000, at: 0)
        let b = telemetry(load: 10, count: 1060, at: 60)
        XCTAssertNil(SystemPowerWindow.between(a, b))
    }

    func testImplausiblePowerIsRefused() {
        // A real increase, but one implying far more than any laptop draws.
        let a = telemetry(load: 0, count: 1000, at: 0)
        let b = telemetry(load: 60 * 500_000, count: 1060, at: 60)   // 500 W
        XCTAssertNil(SystemPowerWindow.between(a, b))
    }

    func testAbsurdTickCountIsRefused() {
        let a = telemetry(load: 0, count: 1000, at: 0)
        let b = telemetry(load: 100, count: 1000 + 200_000, at: 60)
        XCTAssertNil(SystemPowerWindow.between(a, b),
                     "more than a day of 1 Hz ticks between samples is a restart")
    }

    func testNoNewBatchStillYieldsNil() {
        let a = telemetry(load: 1000, count: 1000, at: 0)
        XCTAssertNil(SystemPowerWindow.between(a, a))
    }
}
