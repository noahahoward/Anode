import XCTest
@testable import PowerKit

/// Two field fixes that only show on a pack unlike the one this repo was
/// measured on: the %/hr basis a time-to-empty is divided from, and a pack that
/// drains with the adapter plugged in.
final class BatteryBasisTests: XCTestCase {

    /// `Mac17,5` (MacBook Neo): one cell, 9340 mAh, 4186 mV at 79 %.
    private let neo = BatteryScale(fullChargeCapacity_mAh: 9340, designCapacity_mAh: 9516,
                                   nominalVoltage_V: BatteryScale.nominalVoltage(measured_mV: 4186),
                                   isCalibrated: false)

    private func snapshot(watts: Double, state: Battery.State) -> PowerMonitor.Snapshot {
        PowerMonitor.Snapshot(
            drains: [], apps: [], systemApps: [], gpuApps: [],
            systemAttributionAge: nil, isFullSample: true,
            attributed_W: 0, rails: [], gpu_W: nil,
            fast_W: 0, measured_W: nil, measuredAge: nil,
            smoothed_W: watts, isCalibrated: true,
            smcTotal_W: watts, smcGain: 1, cpuRail_W: nil,
            display_W: nil, memory_W: nil, storage_W: nil, usb_W: nil,
            usbHasUnmeasured: false, usbHasRemembered: false, usbDevices: [],
            displayIsMeasured: false, baseline_W: nil, didJump: false,
            residual_W: watts, rawResidual_W: watts,
            scale: neo, state: state,
            coverage: 0.63, denied: 0, readable: 0, attempted: 0, interval: 2)
    }

    private func state(onAC: Bool = false, mA: Int = -674, mV: Int = 4186) -> Battery.State {
        Battery.State(percent: 79, isCharging: false, onAC: onAC, cycleCount: 12,
                      voltage_mV: mV, amperage_mA: mA,
                      remainingCapacity_mAh: 7399, timeRemaining_min: nil)
    }

    /// The fixture macOS read as 10:11. On the nominal basis, with the
    /// constant-power factor applied on top, it printed about 9h24m.
    func testThePowerTierTimeLandsOnTheGaugeNotEightPercentShort() throws {
        let s = snapshot(watts: 2.821, state: state())
        let hours = try XCTUnwrap(s.projectedRuntime_hr())
        XCTAssertEqual(hours, 10.18, accuracy: 0.3, "macOS said 10:11")
        XCTAssertGreaterThan(hours, 9.8, "back on the nominal basis: ~9.4 h")
    }

    /// The live rate is the nominal one scaled by nominal / live voltage.
    func testTheLiveRateIsOnThePackVoltage() {
        let s = snapshot(watts: 2.821, state: state())
        XCTAssertEqual(s.smoothedLive_pctHr / s.smoothed_pctHr,
                       neo.nominalVoltage_V / 4.186, accuracy: 1e-9)
        XCTAssertEqual(s.smoothedLive_pctHr, 7.215, accuracy: 0.01)
    }

    /// No voltage reading: the nominal basis, exactly as before.
    func testWithoutAVoltageTheRateIsUnchanged() {
        let s = snapshot(watts: 2.821, state: state(mV: 0))
        XCTAssertEqual(s.smoothedLive_pctHr, s.smoothed_pctHr)
    }

    /// The estimator's power tier converts the same way, and still records the
    /// measurement in watts for its cross-check.
    func testTheEstimatorPowerTierUsesTheLiveBasis() {
        let e = DrainRateEstimator()
        let nominal = 3600 * 2.821 / neo.joulesPerPercent
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<5 {
            e.record(remainingCapacity_mAh: 7399 - Double(i), onAC: false, isCharging: false,
                     scale: neo, powerBased_pctHr: nominal, voltage_mV: 4186,
                     at: t0.addingTimeInterval(Double(i) * 2))
        }
        if let est = e.estimate(), est.source == .power {
            XCTAssertEqual(est.percentPerHour, 7.215, accuracy: 0.05)
        }
    }

    // ── Draining on AC ──────────────────────────────────────────────────────

    /// A 12 W brick under a 14 W load: plugged in, and losing ~5 %/hr.
    func testAWeakAdapterStillShowsTheDrain() throws {
        let s = snapshot(watts: 14, state: state(onAC: true, mA: -480, mV: 4100))
        XCTAssertEqual(s.direction, .acIdle)
        XCTAssertTrue(s.isDischargingOnAC)
        let rate = try XCTUnwrap(s.batteryRate_pctHr)
        XCTAssertEqual(rate, -100.0 * 480 / 9340, accuracy: 1e-9)
    }

    /// Held at a limit, the gauge wobbles by a few mA. That is not a drain.
    func testGaugeNoiseOnAdapterIsNotADrain() {
        for mA in [0, -5, -40, -100] {
            let s = snapshot(watts: 6, state: state(onAC: true, mA: mA))
            XCTAssertFalse(s.isDischargingOnAC, "\(mA) mA")
            XCTAssertEqual(s.batteryRate_pctHr, 0)
        }
    }

    // ── Health and cell count ────────────────────────────────────────────────

    /// System Settings' "Maximum Capacity" is NominalChargeCapacity / Design.
    /// `Mac17,9`'s own numbers: 6124 / 6249 = 98.0 %, where full / design read
    /// 95.6 %.
    func testHealthIsNominalOverDesignLikeSystemSettings() {
        let s = BatteryScale(fullChargeCapacity_mAh: 5972, designCapacity_mAh: 6249,
                             nominalVoltage_V: BatteryScale.seedNominalVoltage_V,
                             isCalibrated: false, healthCapacity_mAh: 6124)
        XCTAssertEqual(s.health, 6124.0 / 6249.0, accuracy: 1e-12)
    }

    /// A new pack's nominal capacity reads over its design figure; macOS says 100 %.
    func testHealthIsCappedAtFull() {
        let s = BatteryScale(fullChargeCapacity_mAh: 6300, designCapacity_mAh: 6249,
                             nominalVoltage_V: BatteryScale.seedNominalVoltage_V,
                             isCalibrated: false, healthCapacity_mAh: 6420)
        XCTAssertEqual(s.health, 1)
    }

    /// The per-cell array, when present, is the cell count — even when the
    /// terminal voltage of a nearly empty 3S pack under load rounds to two.
    func testTheCellArrayBeatsTheTerminalVoltage() {
        XCTAssertEqual(BatteryScale.nominalVoltage(measured_mV: 9300),
                       2 * BatteryScale.nominalCellVoltage_V, accuracy: 1e-9,
                       "the failure the array exists to prevent")
        XCTAssertEqual(BatteryScale.nominalVoltage(measured_mV: 9300, cellCount: 3),
                       BatteryScale.seedNominalVoltage_V, accuracy: 1e-9)
        XCTAssertEqual(BatteryScale.nominalVoltage(measured_mV: 4186, cellCount: 1),
                       BatteryScale.nominalCellVoltage_V, accuracy: 1e-9)
        XCTAssertEqual(BatteryScale.nominalVoltage(measured_mV: 12111, cellCount: 0),
                       BatteryScale.seedNominalVoltage_V, accuracy: 1e-9,
                       "an empty array falls back to the voltage")
    }

    // ── The curve above the measured range ──────────────────────────────────

    /// A pack that charges to 100 % lives above the measured table. The run-out
    /// uses the fitted upper slope, which is steeper than the last bin's.
    func testTheTopOfThePackIsNotFlattened() {
        let lastBinSlope = (1.06565 - 1.06178) / 2.5
        XCTAssertGreaterThan(BatteryScale.upperSlope, lastBinSlope)
        XCTAssertEqual(BatteryScale.upperSlope, 0.00231, accuracy: 0.0001)
        XCTAssertEqual(BatteryScale.relativeVoltage(atSoCPercent: 100),
                       1.06565 + BatteryScale.upperSlope * 22.5, accuracy: 1e-9)
    }
}
