import XCTest
@testable import PowerKit
@testable import AnodeApp

/// Time-to-full must count toward a level the machine will actually reach, and
/// must not pretend charging is constant-current right up to it.
///
/// Both halves were wrong: the estimate divided the gap to `fullChargeCapacity_mAh`
/// by the instantaneous current, so on a machine limited to 80% it counted toward a
/// target the charger would never touch and then vanished the moment charging
/// stopped — a countdown that never read zero.
final class ChargeEstimateTests: XCTestCase {

    // ── Fixtures ────────────────────────────────────────────────────────────

    /// The pack in this machine, so the arithmetic below is this machine's.
    private func pack() -> BatteryScale {
        BatteryScale(fullChargeCapacity_mAh: 6202,
                     designCapacity_mAh: 6249,
                     nominalVoltage_V: BatteryScale.seedNominalVoltage_V,
                     isCalibrated: false)
    }

    private func charging(at percent: Double, mA: Int, scale: BatteryScale) -> Battery.State {
        Battery.State(percent: Int(percent.rounded()), isCharging: true, onAC: true,
                      cycleCount: 21, voltage_mV: 12469, amperage_mA: mA,
                      remainingCapacity_mAh: scale.fullChargeCapacity_mAh * percent / 100,
                      timeRemaining_min: nil,
                      notChargingReason: 0, fullyCharged: false)
    }

    /// On AC, deliberately not charging — the shape the machine holds at its limit.
    /// 128 is the `NotChargingReason` this machine reports there.
    private func holding(at percent: Double, scale: BatteryScale,
                         reason: Int = 128, onAC: Bool = true) -> Battery.State {
        Battery.State(percent: Int(percent.rounded()), isCharging: false, onAC: onAC,
                      cycleCount: 21, voltage_mV: 12469, amperage_mA: 0,
                      remainingCapacity_mAh: scale.fullChargeCapacity_mAh * percent / 100,
                      timeRemaining_min: nil,
                      notChargingReason: reason, fullyCharged: false)
    }

    private func snapshot(_ state: Battery.State, scale: BatteryScale,
                          target: ChargeTarget.Level?) -> PowerMonitor.Snapshot {
        PowerMonitor.Snapshot(
            drains: [], apps: [], systemApps: [], gpuApps: [],
            systemAttributionAge: nil, isFullSample: true,
            attributed_W: 0, rails: [], gpu_W: nil, fast_W: 0,
            measured_W: nil, measuredAge: nil, smoothed_W: 10, isCalibrated: true,
            smcTotal_W: 10, smcGain: 1, cpuRail_W: nil,
            display_W: nil, memory_W: nil, storage_W: nil, usb_W: nil,
            usbHasUnmeasured: false, usbHasRemembered: false, usbDevices: [],
            displayIsMeasured: false, baseline_W: nil, didJump: false,
            residual_W: 0, rawResidual_W: 0,
            scale: scale, state: state,
            coverage: 1, denied: 0, readable: 1, attempted: 1, interval: 2,
            chargeTarget: target)
    }

    /// A throwaway suite, under the project's own test prefix and a STABLE name.
    ///
    /// This built a fresh `chargeLimitTests.<UUID>` suite per call and never tore
    /// one down — 990 files in the real `~/Library/Preferences`, under a prefix
    /// nobody thought to look for because it did not match the one the cleanup was
    /// written against. Every call now reuses one domain and empties it first, so
    /// the tests stay isolated from each other without leaving a trail.
    private func store() -> UserDefaults {
        (try? TestDefaults.make(owner: "ChargeEstimate").defaults) ?? .standard
    }

    // ── The target ──────────────────────────────────────────────────────────

    /// THE headline defect. At 60% on a machine limited to 80%, a projection to
    /// 100% claims twice the wait — 41 min against 21 — and the extra 20 are time
    /// the charger is never going to spend.
    func testAKnownLimitIsTargetedRatherThanFullCapacity() {
        let scale = pack()
        let s = snapshot(charging(at: 60, mA: 3600, scale: scale), scale: scale,
                         target: ChargeTarget.Level(percent: 80, isLearnedLimit: true))
        guard let est = s.chargeEstimate else { return XCTFail("no estimate while charging") }

        XCTAssertEqual(est.target.percent, 80)
        // 20 points at 58.05 %/hr is 20.7 min, plus the measured terminal taper.
        XCTAssertEqual(est.hours * 60, 21.5, accuracy: 0.15)

        let toFull = (100.0 - 60.0) / (100.0 * 3600.0 / 6202.0)
        XCTAssertLessThan(est.hours, toFull * 0.6,
                          "targeting the limit must be far shorter than targeting 100%")
    }

    /// At the limit there is no wait left, so there is no number. This is the end
    /// the old estimate never reached: it went from "17 min" to nil the instant
    /// the charger stopped, having never counted down to zero.
    func testAtOrAboveTheLimitThereIsNoCountdown() {
        let scale = pack()
        let limit = ChargeTarget.Level(percent: 80, isLearnedLimit: true)
        for percent in [80.0, 80.5, 92.0] {
            let s = snapshot(charging(at: percent, mA: 3600, scale: scale),
                             scale: scale, target: limit)
            XCTAssertNil(s.chargeEstimate,
                         "\(percent)% is at or past the target — nothing to count down")
        }
    }

    /// Nothing in IOKit states the limit, so on a machine that has never been seen
    /// to stop there is no limit to target. The fallback is the pack's own full
    /// charge and it is LABELLED as such, rather than a percentage nobody observed.
    func testAnUnknownLimitDegradesToFullChargeAndSaysSo() {
        let scale = pack()
        let learner = ChargeLimitLearner(defaults: store())
        let target = learner.target(atPercent: 60, isCharging: true)

        XCTAssertEqual(target.percent, 100)
        XCTAssertFalse(target.isLearnedLimit)

        let s = snapshot(charging(at: 60, mA: 3600, scale: scale), scale: scale, target: target)
        guard let est = s.chargeEstimate else { return XCTFail("no estimate while charging") }
        // Constant-current only. The taper constant was measured against an 80%
        // limit and nothing has ever been observed above 92% on this machine, so
        // spending it here would be inventing a number for an unsampled region.
        XCTAssertEqual(est.hours * 60, 41.3, accuracy: 0.15)
    }

    /// The machine tops up past its limit sometimes — one recorded session ran
    /// 80 -> 92. Reporting "already there" while the gauge visibly climbs is the
    /// same lie as counting to 100, pointed the other way.
    func testChargingAboveTheRememberedLimitYieldsTheLimit() {
        let learner = ChargeLimitLearner(defaults: store())
        learn(learner, at: 80)

        XCTAssertEqual(learner.target(atPercent: 79, isCharging: true).percent, 80)
        XCTAssertEqual(learner.target(atPercent: 85, isCharging: true).percent, 100)
        XCTAssertFalse(learner.target(atPercent: 85, isCharging: true).isLearnedLimit)
        // Sitting at 85 NOT charging is the machine having stopped somewhere new,
        // not an override in progress; the remembered limit still describes it.
        XCTAssertTrue(learner.target(atPercent: 85, isCharging: false).isLearnedLimit)
    }

    // ── The taper ───────────────────────────────────────────────────────────

    /// The two recorded charge sessions that actually terminated at 80% and held
    /// there (91 and 68 minutes), replayed minute by minute. At each minute the
    /// model is given only what the app has live — the current charge and the rate
    /// over that minute — and asked how long until the charger stops. The answer
    /// is scored against how long it really took.
    ///
    /// Constant current is biased SHORT everywhere on both curves, because it never
    /// pays for the final approach. This is the measurement `ChargeCurve` exists to
    /// answer, so it is the measurement that guards it.
    func testTheTaperModelBeatsConstantCurrentOnTheRecordedCurves() {
        // %SoC on the mAh basis, one sample per minute, from history.sqlite.
        let sessionA: [Double] = [41, 42.2001, 43.4667, 44.6666, 45.933, 47.1, 48.2333,
                                  49.3, 50.4667, 51.5667, 52.6667, 53.9333, 55.2999, 56.5,
                                  57.7, 59, 60.3333, 61.5333, 62.7666, 64.1667, 65.4,
                                  66.6333, 67.8, 68.8667, 70.1333, 71.2667, 72.4, 73.5333,
                                  74.6666, 75.7667, 76.9333, 78, 79, 79.9, 80]
        let sessionB: [Double] = [72, 72.6445, 73.4819, 74.1667, 75, 75.8975, 76.6031,
                                  77.4, 78.0999, 79, 79.7416, 80]

        var constantCurrent: [Double] = []
        var withTaper: [Double] = []
        for curve in [sessionA, sessionB] {
            for i in 0..<(curve.count - 1) {
                let rate = (curve[i + 1] - curve[i]) * 60     // one-minute step -> %/hr
                let headroom = 80.0 - curve[i]
                let actual = Double(curve.count - 1 - i)      // minutes to arrival
                let flat = ChargeCurve.hours(headroom_pct: headroom, rate_pctHr: rate,
                                             tapers: false)!
                let taper = ChargeCurve.hours(headroom_pct: headroom, rate_pctHr: rate,
                                              tapers: true)!
                constantCurrent.append(abs(flat * 60 - actual))
                withTaper.append(abs(taper * 60 - actual))
            }
        }
        XCTAssertEqual(constantCurrent.count, 45)
        let ccMAE = constantCurrent.reduce(0, +) / 45
        let tpMAE = withTaper.reduce(0, +) / 45
        XCTAssertEqual(ccMAE, 1.435, accuracy: 0.01)
        XCTAssertEqual(tpMAE, 0.995, accuracy: 0.01)
        XCTAssertLessThan(tpMAE, ccMAE * 0.75, "the taper must be a clear improvement, not a wash")
    }

    /// The taper is claimed only where it was measured. Nothing above 92% has ever
    /// been observed on this machine, so a projection to 100% gets the bare
    /// constant-current figure rather than a constant borrowed from an 80% limit.
    func testNoTaperIsClaimedForATargetThatWasNeverObserved() {
        let flat = ChargeCurve.hours(headroom_pct: 20, rate_pctHr: 60, tapers: false)!
        let taper = ChargeCurve.hours(headroom_pct: 20, rate_pctHr: 60, tapers: true)!
        XCTAssertEqual(flat, 20.0 / 60.0, accuracy: 1e-9)
        XCTAssertEqual(taper - flat, ChargeCurve.terminalTaper_hr, accuracy: 1e-9)
    }

    /// nil, not zero and not a fallback, when there is nothing to project from.
    func testNoRateMeansNoAnswer() {
        XCTAssertNil(ChargeCurve.hours(headroom_pct: 20, rate_pctHr: 0, tapers: true))
        XCTAssertNil(ChargeCurve.hours(headroom_pct: 20, rate_pctHr: -60, tapers: true))
        XCTAssertNil(ChargeCurve.hours(headroom_pct: 0, rate_pctHr: 60, tapers: true))
        XCTAssertNil(ChargeCurve.hours(headroom_pct: -3, rate_pctHr: 60, tapers: true))
    }

    // ── Learning the limit ──────────────────────────────────────────────────

    private func learn(_ l: ChargeLimitLearner, at percent: Double,
                       reason: Int = 128, onAC: Bool = true) {
        let scale = pack()
        let s = holding(at: percent, scale: scale, reason: reason, onAC: onAC)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        l.observe(s, percent: percent, at: t0)
        l.observe(s, percent: percent, at: t0 + 600)
    }

    /// A momentary refusal to charge is not a limit. Only a sustained one is.
    ///
    /// Stated in ABSOLUTE seconds rather than relative to `holdToConfirm`, so the
    /// window is pinned into the band the measurement justifies instead of moving
    /// with whatever the constant happens to be. One minute is inside the settle
    /// after a charger tops off; the three genuine holds in history lasted 68, 91
    /// and 435 minutes, so ten is unambiguous.
    func testALimitIsLearnedOnlyAfterTheHoldIsSustained() {
        let l = ChargeLimitLearner(defaults: store())
        let scale = pack()
        let s = holding(at: 80, scale: scale)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)

        l.observe(s, percent: 80, at: t0)
        l.observe(s, percent: 80, at: t0 + 60)
        XCTAssertNil(l.limit, "a one-minute pause is not a limit")

        l.observe(s, percent: 80, at: t0 + 600)
        XCTAssertEqual(l.limit, 80, "a ten-minute hold is")
    }

    /// THE TRAP, verified live: `NotChargingReason` keeps its last value after the
    /// adapter is pulled — it read 128 at 83% on battery. Without the `onAC` gate
    /// the machine learns a "limit" at whatever charge it was unplugged at.
    func testANonZeroReasonOffACTeachesNothing() {
        let l = ChargeLimitLearner(defaults: store())
        learn(l, at: 83, reason: 128, onAC: false)
        XCTAssertNil(l.limit, "off AC there is nothing to refuse, so nothing to learn")
    }

    /// Charging normally reports no reason. A hold has to be deliberate.
    func testAZeroReasonTeachesNothing() {
        let l = ChargeLimitLearner(defaults: store())
        learn(l, at: 80, reason: 0)
        XCTAssertNil(l.limit)
    }

    /// A machine that will not charge at 8% has a fault, not a preference, and
    /// remembering that as the user's limit would poison every later estimate.
    func testAFaultLowDownIsNotRememberedAsALimit() {
        let l = ChargeLimitLearner(defaults: store())
        learn(l, at: 8)
        XCTAssertNil(l.limit)
        learn(l, at: 99.5)
        XCTAssertNil(l.limit, "at the top the pack is simply full — FullyCharged says so")
    }

    /// A level still drifting is still settling. The clock restarts, so the hold
    /// has to be steady for the whole window rather than merely long.
    func testTheHoldClockRestartsWhenTheLevelDrifts() {
        let l = ChargeLimitLearner(defaults: store())
        let scale = pack()
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        l.observe(holding(at: 78, scale: scale), percent: 78, at: t0)
        l.observe(holding(at: 80, scale: scale), percent: 80, at: t0 + 600)
        XCTAssertNil(l.limit, "the level moved, so the elapsed time belongs to no level")

        l.observe(holding(at: 80, scale: scale), percent: 80, at: t0 + 1200)
        XCTAssertEqual(l.limit, 80)
    }

    /// The limit is worth nothing if it is forgotten at quit: the app is normally
    /// launched into a machine already sitting at its limit, where there is no
    /// stop to observe. Same bargain `USBPowerTracker` makes with device costs.
    func testTheLimitIsRememberedAcrossLaunches() {
        let d = store()
        learn(ChargeLimitLearner(defaults: d), at: 80)
        XCTAssertEqual(ChargeLimitLearner(defaults: d).limit, 80)
    }

    /// A limit is a setting, not a noisy measurement, so a new one REPLACES the
    /// old rather than averaging with it — the mean of 80 and 100 is a level the
    /// machine will never stop at.
    func testANewLimitReplacesTheOldRatherThanAveraging() {
        let d = store()
        let l = ChargeLimitLearner(defaults: d)
        learn(l, at: 80)
        learn(l, at: 90)
        XCTAssertEqual(l.limit, 90)
        XCTAssertEqual(ChargeLimitLearner(defaults: d).limit, 90)
    }

    // ── Sitting at the limit ────────────────────────────────────────────────

    /// "Not charging" at 80% reads as a fault. "Held at 80%" is what is happening.
    func testHeldAtTheLimitIsDistinctFromMerelyNotCharging() {
        let scale = pack()
        let limit = ChargeTarget.Level(percent: 80, isLearnedLimit: true)

        let held = snapshot(holding(at: 80, scale: scale), scale: scale, target: limit)
        XCTAssertEqual(held.direction, .acIdle)
        XCTAssertTrue(held.isHeldAtChargeLimit)
        XCTAssertNil(held.chargeEstimate, "nothing is charging, so there is nothing to project")

        // Plugged in well below the limit and not charging: something else is going
        // on and we must not call that "held at 80%".
        let low = snapshot(holding(at: 55, scale: scale), scale: scale, target: limit)
        XCTAssertFalse(low.isHeldAtChargeLimit)

        // Stopped at 92 after an override. On AC, not charging, but nowhere near
        // the 80% limit — so it is not being held at it.
        let over = snapshot(holding(at: 92, scale: scale), scale: scale, target: limit)
        XCTAssertFalse(over.isHeldAtChargeLimit)

        // No limit ever learned: "not charging" is all we honestly know.
        let unknown = snapshot(holding(at: 80, scale: scale), scale: scale,
                               target: ChargeTarget.Level(percent: 100, isLearnedLimit: false))
        XCTAssertFalse(unknown.isHeldAtChargeLimit)
    }

    /// Before the first tick has fed the learner there is no target, and without a
    /// target there is no honest countdown.
    func testNoTargetYetMeansNoEstimate() {
        let scale = pack()
        let s = snapshot(charging(at: 60, mA: 3600, scale: scale), scale: scale, target: nil)
        XCTAssertNil(s.chargeEstimate)
        XCTAssertNil(s.timeToFull_hr)
    }

    // ── What the card says ──────────────────────────────────────────────────

    /// The card has to name the target and admit the figure is a projection.
    /// A bare "charging" beside a countdown that was silently heading for 100%
    /// is how the wrong target stayed invisible for as long as it did.
    func testTheCardNamesTheTargetAndMarksTheEstimate() {
        let scale = pack()

        let toLimit = GlanceCardView.model(
            from: snapshot(charging(at: 60, mA: 3600, scale: scale), scale: scale,
                           target: ChargeTarget.Level(percent: 80, isLearnedLimit: true)),
            drain: nil)
        XCTAssertEqual(toLimit?.sourceLabel, "charging to 80% · estimated")
        // 20 points at 58.05 %/hr plus the taper is 21.5 min. The same headline
        // built against 100% reads 41m — the defect, in the one place it shows.
        XCTAssertEqual(toLimit?.headline, "21m")

        let toFull = GlanceCardView.model(
            from: snapshot(charging(at: 60, mA: 3600, scale: scale), scale: scale,
                           target: ChargeTarget.Level(percent: 100, isLearnedLimit: false)),
            drain: nil)
        XCTAssertEqual(toFull?.sourceLabel, "charging to full · estimated",
                       "no limit is known, so no percentage may be named")

        // Sitting at the limit: finished, not faulty.
        let held = GlanceCardView.model(
            from: snapshot(holding(at: 80, scale: scale), scale: scale,
                           target: ChargeTarget.Level(percent: 80, isLearnedLimit: true)),
            drain: nil)
        XCTAssertEqual(held?.sourceLabel, "held at 80% limit")

        let idle = GlanceCardView.model(
            from: snapshot(holding(at: 55, scale: scale), scale: scale,
                           target: ChargeTarget.Level(percent: 80, isLearnedLimit: true)),
            drain: nil)
        XCTAssertEqual(idle?.sourceLabel, "not charging")
    }
}
