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
