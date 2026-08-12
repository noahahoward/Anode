import XCTest
@testable import AnodeApp
@testable import PowerKit

/// The Runtime cost column showed "—" for every row, on every machine, always.
///
/// Two gates were doing it, and the fixture numbers below are the ones MEASURED on
/// this machine while diagnosing it (M5 Pro, 8 sweeps, adapter detached, 83% charge,
/// 214,180 J in the pack): idle system power 3.97 W, the busiest application 0.0404 W
/// and the fifth 0.0103 W; the same machine's smoothed total reached 21 W under load.
///
/// Everything here fails against the old implementation, which is the point — a test
/// that only described the new gates would have passed before the fix as well.
final class RuntimeCostTests: XCTestCase {

    /// Measured: the busiest app on an idle machine is 1.02% of system power. The
    /// old floor rejected anything under 0.5%, so this row passed — and the FIFTH
    /// row, at 0.26%, did not, despite being worth 2.3 minutes.
    func testTheBusiestAppOnAnIdleMachineReportsMinutes() {
        let minutes = RuntimeCost.minutes(appWatts: 0.0404, systemWatts: 3.9745,
                                          remainingEnergy_J: 214_180)
        XCTAssertEqual(try XCTUnwrap(minutes), 9.2, accuracy: 0.2)
    }

    /// The row the share floor was silently discarding. 0.26% of the machine, and
    /// still over two minutes of runtime.
    func testAnAppWellUnderTheOldShareFloorStillReportsWhatItCosts() {
        let share = 0.0103 / 3.9745
        XCTAssertLessThan(share, 0.005, "fixture no longer exercises the old floor")
        let minutes = RuntimeCost.minutes(appWatts: 0.0103, systemWatts: 3.9745,
                                          remainingEnergy_J: 214_180)
        XCTAssertEqual(try XCTUnwrap(minutes), 2.3, accuracy: 0.2)
    }

    /// The floor is on the ANSWER, not on the share — which is what the old
    /// comment's own justification said it was for ("below it the answer rounds to
    /// under a minute"). Whether a given share is worth a minute depends entirely on
    /// system power: the SAME app on the same machine under load is worth 19
    /// seconds, and that is the row that should be blank.
    func testTheSameAppIsBlankedOnlyWhenTheAnswerRoundsToNothing() {
        let underLoad = RuntimeCost.minutes(appWatts: 0.0404, systemWatts: 21.0,
                                            remainingEnergy_J: 214_180)
        XCTAssertNil(underLoad, "19 seconds is noise printed as a measurement")
    }

    func testTheFloorIsExactlyOneMinute() {
        XCTAssertEqual(RuntimeCost.minimumReportable_min, 1)
        // Straddle it: the same system and pack, with the app's draw chosen either
        // side of the one-minute answer.
        let energy = 214_180.0, system = 4.0
        // seconds = E * (1/(P-a) - 1/P); solve a for 60 s and step either side.
        let target = 60.0
        let a = system - 1.0 / (target / energy + 1.0 / system)
        XCTAssertNil(RuntimeCost.minutes(appWatts: a * 0.9, systemWatts: system,
                                         remainingEnergy_J: energy))
        XCTAssertNotNil(RuntimeCost.minutes(appWatts: a * 1.2, systemWatts: system,
                                            remainingEnergy_J: energy))
    }

    /// The reciprocal runs away as an app approaches the whole machine's draw. This
    /// guard is the one gate from the original that was worth keeping.
    func testAnAppThatWouldExplainTheWholeMachineIsRefused() {
        XCTAssertNil(RuntimeCost.minutes(appWatts: 9.5, systemWatts: 10,
                                         remainingEnergy_J: 214_180))
    }

    func testNothingDrawingMeansNothingToSay() {
        XCTAssertNil(RuntimeCost.minutes(appWatts: 0, systemWatts: 4,
                                         remainingEnergy_J: 214_180))
        XCTAssertNil(RuntimeCost.minutes(appWatts: 0.04, systemWatts: 0,
                                         remainingEnergy_J: 214_180))
        XCTAssertNil(RuntimeCost.minutes(appWatts: 0.04, systemWatts: 4,
                                         remainingEnergy_J: 0))
    }

    /// The counterfactual is a reciprocal, not a proportion. The subtractive form
    /// that looks right is linear in the load fraction and goes negative once an app
    /// exceeds the whole battery, so the identity is asserted directly.
    func testTheAnswerIsTheDifferenceOfTwoRuntimes() {
        let energy = 200_000.0, system = 5.0, app = 0.5
        let minutes = try? XCTUnwrap(RuntimeCost.minutes(appWatts: app, systemWatts: system,
                                                         remainingEnergy_J: energy))
        let expected = (energy / (system - app) - energy / system) / 60
        XCTAssertEqual(minutes ?? 0, expected, accuracy: 1e-9)
    }

    // ── The on-AC gate ──────────────────────────────────────────────────────

    /// The second half of the bug: the column blanked entirely whenever the adapter
    /// was attached, so on a plugged-in laptop every row was "—" whatever the
    /// numbers said.
    ///
    /// Every other battery figure in the window — the %/hr column beside it, the
    /// ledger, the graph, the trailing window — is reported on AC too, and each is
    /// the same kind of statement. Both quantities the formula reads are measured on
    /// AC: the pack's charge, and the machine's draw.
    func testTheColumnStillAnswersWhileOnTheAdapter() {
        let onAC = snapshot(onAC: true)
        XCTAssertNotNil(RuntimeCost.minutes(appWatts: 0.0404, snapshot: onAC),
                        "plugging in blanked the whole column")
        let onBattery = snapshot(onAC: false)
        XCTAssertEqual(RuntimeCost.minutes(appWatts: 0.0404, snapshot: onAC),
                       RuntimeCost.minutes(appWatts: 0.0404, snapshot: onBattery),
                       "the answer is about the pack and the draw, not about the cable")
    }

    /// A machine with no battery has no runtime for quitting anything to extend.
    func testNoPackMeansNoAnswer() {
        XCTAssertNil(RuntimeCost.minutes(appWatts: 0.0404, snapshot: snapshot(hasPack: false)))
    }

    private func snapshot(onAC: Bool = false, hasPack: Bool = true)
        -> PowerMonitor.Snapshot {
        let live = Battery.State(percent: 83, isCharging: false, onAC: onAC,
                                 cycleCount: 21, voltage_mV: 12435,
                                 amperage_mA: -641, remainingCapacity_mAh: 4915,
                                 timeRemaining_min: 390)
        return PowerMonitor.Snapshot(
            drains: [], apps: [], systemApps: [], gpuApps: [],
            systemAttributionAge: nil, isFullSample: true,
            attributed_W: 0.3, rails: [], gpu_W: nil, fast_W: 0.3,
            measured_W: nil, measuredAge: nil,
            smoothed_W: 3.9745, isCalibrated: true,
            smcTotal_W: 3.9745, smcGain: 1, cpuRail_W: 1,
            display_W: nil, memory_W: nil, storage_W: nil, usb_W: nil,
            usbHasUnmeasured: false, usbHasRemembered: false, usbDevices: [],
            displayIsMeasured: false, baseline_W: nil, didJump: false,
            residual_W: 3, rawResidual_W: 3,
            scale: makeMachineScale(), state: hasPack ? live : nil,
            coverage: 0.63, denied: 300, readable: 600, attempted: 900, interval: 2)
    }
}
