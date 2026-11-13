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
    private func store(_ test: String = #function) -> UserDefaults {
        // Never the process's standard defaults, whatever goes wrong: a suite of its own, or a loud failure.
        (try? TestDefaults.make(owner: "ChargeEstimate", test: test).defaults)
            ?? UserDefaults(suiteName: "com.anode.tests.ChargeEstimate.fallback")!
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
        // Flat current to the 92 % knee, then the constant-voltage decay to C/20.
        // Constant current all the way would say 41.3 min and then vanish at
        // 100 % while the pack was still charging.
        let r = 40 / (41.3 / 60)   // the rate the fixture charges at
        let expected = ChargeCurve.toFull(headroom_pct: 40, rate_pctHr: r) * 60
        XCTAssertEqual(est.hours * 60, expected, accuracy: 0.2)
        XCTAssertGreaterThan(est.hours * 60, 41.3, "the tail costs time")
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
                // Constant current is the plain division. NOT `tapers: false`, which
                // now prices the constant-voltage tail on the way to 100 % and so
                // reads this 80 % headroom as the last points below full.
                let flat = headroom / rate
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
    /// Into a learned limit: the measured terminal step, nothing more.
    func testALimitGetsOnlyTheMeasuredTerminalTaper() {
        let taper = ChargeCurve.hours(headroom_pct: 20, rate_pctHr: 60, tapers: true)!
        XCTAssertEqual(taper, 20.0 / 60.0 + ChargeCurve.terminalTaper_hr, accuracy: 1e-9)
    }

    /// To full: flat to the knee, exponential decay to termination after it.
    func testTheApproachToFullIsPricedByTheDecay() {
        let r = 60.0, tail = 100 - ChargeCurve.constantVoltageKnee
        let decay = log(r / ChargeCurve.terminationRate_pctHr)
        // From 80 %: 12 points flat, then the 8-point tail.
        XCTAssertEqual(ChargeCurve.hours(headroom_pct: 20, rate_pctHr: r, tapers: false)!,
                       12 / r + tail / r * decay, accuracy: 1e-9)
        // Continuous at the knee: approached from either side it is the same time.
        let below = ChargeCurve.toFull(headroom_pct: tail + 1e-9, rate_pctHr: r)
        let above = ChargeCurve.toFull(headroom_pct: tail, rate_pctHr: r)
        XCTAssertEqual(below, above, accuracy: 1e-6)
        // Longer than constant current, and never shorter.
        for h in stride(from: 1.0, through: 90, by: 1) {
            XCTAssertGreaterThanOrEqual(ChargeCurve.toFull(headroom_pct: h, rate_pctHr: r),
                                        h / r - 1e-12)
        }
        // A current already at termination is the charger finishing.
        XCTAssertEqual(ChargeCurve.toFull(headroom_pct: 1, rate_pctHr: 4), 0.25, accuracy: 1e-9)
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

    // ── Charge Control's own hold is not the Mac's limit ────────────────────

    /// Charge Control stops charging at a level Anode chose, and that looks exactly
    /// like a limit the Mac enforces: on AC, not charging, a non-zero reason. If it
    /// were learned, switching Charge Control off would leave "charging to 80 %"
    /// behind for a Mac that charges to 100.
    func testNoLearningWhileChargeControlHolds() {
        let d = store()
        let l = ChargeLimitLearner(defaults: d)
        let s = holding(at: 80, scale: pack())
        let t0 = Date(timeIntervalSinceReferenceDate: 0)

        // Every minute for fifteen: three times the confirmation window.
        for minute in 0...15 {
            l.observe(s, percent: 80, at: t0 + Double(minute) * 60, anodeHolding: true)
        }
        XCTAssertNil(l.limit, "a hold Anode imposed says nothing about the Mac's own limit")
        XCTAssertNil(ChargeLimitLearner(defaults: d).limit, "and nothing was stored")
    }

    /// A hold that began before Charge Control was switched on is the Mac's, but
    /// time spent under Charge Control's limit must not be credited to it: the
    /// clock is dropped, not paused, so the Mac has to show a full window of its
    /// own again.
    func testAHoldInProgressIsDroppedWhenChargeControlTakesOver() {
        let l = ChargeLimitLearner(defaults: store())
        let s = holding(at: 80, scale: pack())
        let t0 = Date(timeIntervalSinceReferenceDate: 0)

        l.observe(s, percent: 80, at: t0)                              // a hold begins
        l.observe(s, percent: 80, at: t0 + 200)                        // 200 s in
        l.observe(s, percent: 80, at: t0 + 250, anodeHolding: true)    // Charge Control on
        l.observe(s, percent: 80, at: t0 + 400, anodeHolding: true)
        l.observe(s, percent: 80, at: t0 + 500)                        // and off again
        XCTAssertNil(l.limit,
                     "500 s since the hold began, but the clock must not have run through Charge Control")

        l.observe(s, percent: 80, at: t0 + 700)                        // 200 s into the new hold
        XCTAssertNil(l.limit, "the new hold has not yet lasted the window")
        l.observe(s, percent: 80, at: t0 + 800)                        // 300 s into it
        XCTAssertEqual(l.limit, 80, "the Mac's own hold, once Charge Control is off, is learned as ever")
    }

    /// Charge Control does not take away what the Mac already taught. Even reaching
    /// full on the adapter, which forgets a limit in the ordinary run of things, is
    /// Charge Control's doing while it is on, and is not evidence about the Mac.
    func testAnAlreadyLearnedLimitIsLeftAloneWhileChargeControlHolds() {
        let d = store()
        let l = ChargeLimitLearner(defaults: d)
        learn(l, at: 80)
        XCTAssertEqual(l.limit, 80)

        let scale = pack()
        let t0 = Date(timeIntervalSinceReferenceDate: 9000)
        l.observe(holding(at: 60, scale: scale), percent: 60, at: t0, anodeHolding: true)
        l.observe(holding(at: 60, scale: scale), percent: 60, at: t0 + 600, anodeHolding: true)
        let full = Battery.State(percent: 100, isCharging: false, onAC: true,
                                 cycleCount: 21, voltage_mV: 12900, amperage_mA: 0,
                                 remainingCapacity_mAh: scale.fullChargeCapacity_mAh,
                                 timeRemaining_min: nil,
                                 notChargingReason: 0, fullyCharged: true)
        l.observe(full, percent: 100, at: t0 + 700, anodeHolding: true)

        XCTAssertEqual(l.limit, 80, "neither a hold nor a full pack under Charge Control changes it")
        XCTAssertEqual(ChargeLimitLearner(defaults: d).limit, 80)
    }

    // ── Charge Control's limit replaces what was learned ────────────────────

    /// While Charge Control is on, the limit the card names is the one Charge
    /// Control holds. A limit learned earlier (Optimized Battery Charging's 80) is
    /// the Mac's, is left in the store untouched, and must not be the one shown.
    func testChargeControlLimitReplacesALearnedLimit() {
        XCTAssertEqual(ChargeTarget.limit(learned: 80, chargeControl: 90), 90)
    }

    /// 100 is "no limit", exactly as an absent learned limit is, and it is not
    /// read as a level to stop at: the learned 80 must not come back either.
    func testChargeControlAtOneHundredMeansNoLimit() {
        XCTAssertNil(ChargeTarget.limit(learned: 80, chargeControl: 100))
        XCTAssertNil(ChargeTarget.limit(learned: nil, chargeControl: 100))
    }

    func testLearnedLimitIsUsedWhenChargeControlIsOff() {
        XCTAssertEqual(ChargeTarget.limit(learned: 80, chargeControl: nil), 80)
    }

    func testNoLimitAtAllWhenNeitherExists() {
        XCTAssertNil(ChargeTarget.limit(learned: nil, chargeControl: nil))
        XCTAssertEqual(ChargeTarget.limit(learned: nil, chargeControl: 90), 90,
                       "Charge Control needs nothing learned")
    }

    /// Charge Control's limit is a GAUGE percent (the integer the menu bar shows,
    /// which is what the charge controller compares against). Everything the
    /// target feeds is on the mAh basis, so it is divided by the gauge/mAh ratio —
    /// and 100 is judged BEFORE that, or 100 / 1.05 = 95 would become a limit.
    func testChargeControlLimitIsConvertedToTheMAhBasis() throws {
        let ratio = 1.05
        XCTAssertEqual(try XCTUnwrap(ChargeTarget.limit(learned: 76, chargeControl: 90, gaugeRatio: ratio)),
                       90 / 1.05, accuracy: 1e-9)
        XCTAssertNil(ChargeTarget.limit(learned: 76, chargeControl: 100, gaugeRatio: ratio))
        // A ratio that means nothing is not applied.
        for bad in [0.0, -1.0, .nan, .infinity] {
            XCTAssertEqual(ChargeTarget.limit(learned: nil, chargeControl: 90, gaugeRatio: bad), 90)
        }
        // The learned limit is already on the mAh basis and is never converted.
        XCTAssertEqual(ChargeTarget.limit(learned: 76, chargeControl: nil, gaugeRatio: ratio), 76)
    }

    func testTheLearnersTargetFollowsChargeControlWhileItIsOn() {
        let learner = ChargeLimitLearner(defaults: store())
        learn(learner, at: 76)

        let cc = learner.target(atPercent: 60, isCharging: true, chargeControlLimit: 90)
        XCTAssertEqual(cc, ChargeTarget.Level(percent: 90, isLearnedLimit: true),
                       "a learned 76 must not be what the card counts down to")

        let full = learner.target(atPercent: 60, isCharging: true, chargeControlLimit: 100)
        XCTAssertEqual(full, ChargeTarget.Level(percent: 100, isLearnedLimit: false))

        let off = learner.target(atPercent: 60, isCharging: true, chargeControlLimit: nil)
        XCTAssertEqual(off, ChargeTarget.Level(percent: 76, isLearnedLimit: true))

        XCTAssertEqual(learner.limit, 76, "choosing a target never edits what was learned")
    }

    /// Charging visibly past Charge Control's limit is the same lie as counting
    /// to a limit that is not binding, so the overshoot rule covers it too.
    func testChargingPastChargeControlsLimitYieldsFull() {
        let learner = ChargeLimitLearner(defaults: store())
        XCTAssertEqual(learner.target(atPercent: 85, isCharging: true, chargeControlLimit: 80),
                       ChargeTarget.Level(percent: 100, isLearnedLimit: false))
        XCTAssertEqual(learner.target(atPercent: 85, isCharging: false, chargeControlLimit: 80),
                       ChargeTarget.Level(percent: 80, isLearnedLimit: true))
    }

    // ── The card, with gauge and mAh disagreeing ────────────────────────────

    /// A pack whose gauge reads `gauge` while the mAh basis reads `mAhPercent`,
    /// like the real one (80 against 76). The other fixtures make the two equal,
    /// which hides every basis defect.
    private func skewed(gauge: Int, mAhPercent: Double, charging: Bool, scale: BatteryScale)
        -> Battery.State {
        Battery.State(percent: gauge, isCharging: charging, onAC: true,
                      cycleCount: 21, voltage_mV: 12469, amperage_mA: charging ? 3600 : 0,
                      remainingCapacity_mAh: scale.fullChargeCapacity_mAh * mAhPercent / 100,
                      timeRemaining_min: nil,
                      notChargingReason: charging ? 0 : 128, fullyCharged: false)
    }

    /// THE REPORTED SYMPTOM, without a monitor. Charge Control holds at 90 and the
    /// Mac had once been seen holding at 80 (76 on the mAh basis). The card said
    /// "charging to 80%", then "charging to full", then a bare "not charging" at
    /// the real hold. It has to say 90 all the way and "held at 90%" at the end.
    func testTheCardFollowsChargeControlsLimitNotTheLearnedOne() {
        let scale = pack()
        let learner = ChargeLimitLearner(defaults: store())
        learn(learner, at: 76)

        // Charging at gauge 70.
        let charging = skewed(gauge: 70, mAhPercent: 66.5, charging: true, scale: scale)
        let toTarget = learner.target(atPercent: scale.chargePercent(charging), isCharging: true,
                                      chargeControlLimit: 90, gaugeRatio: scale.gaugeRatio(charging))
        let c = GlanceCardView.model(from: snapshot(charging, scale: scale, target: toTarget),
                                     drain: nil, shared: nil)
        XCTAssertEqual(c?.sourceLabel, "charging to 90% · estimated")

        // Held at gauge 90, which is 85.5 on the mAh basis.
        let hold = skewed(gauge: 90, mAhPercent: 85.5, charging: false, scale: scale)
        let atHold = learner.target(atPercent: scale.chargePercent(hold), isCharging: false,
                                    chargeControlLimit: 90, gaugeRatio: scale.gaugeRatio(hold))
        let heldSnap = snapshot(hold, scale: scale, target: atHold)
        XCTAssertTrue(heldSnap.isHeldAtChargeLimit)
        XCTAssertEqual(GlanceCardView.model(from: heldSnap, drain: nil, shared: nil)?.sourceLabel,
                       "held at 90% limit")

        // And the old behaviour, which this replaces: the stale learned target.
        let stale = learner.target(atPercent: scale.chargePercent(hold), isCharging: false)
        XCTAssertFalse(snapshot(hold, scale: scale, target: stale).isHeldAtChargeLimit)
        // An unconverted 90 would miss the band too, which is why the ratio is applied.
        let raw = ChargeTarget.Level(percent: 90, isLearnedLimit: true)
        XCTAssertFalse(snapshot(hold, scale: scale, target: raw).isHeldAtChargeLimit)
    }

    func testTheGaugeRatioIsTheGaugeOverTheMAhBasis() {
        let scale = pack()
        let s = skewed(gauge: 80, mAhPercent: 76, charging: false, scale: scale)
        XCTAssertEqual(scale.gaugeRatio(s), 80.0 / 76.0, accuracy: 1e-9)
        // Unavailable either way: an unconverted number beats one scaled by nothing.
        XCTAssertEqual(scale.gaugeRatio(skewed(gauge: 80, mAhPercent: 0.5, charging: false, scale: scale)), 1)
        XCTAssertEqual(scale.gaugeRatio(skewed(gauge: 0, mAhPercent: 50, charging: false, scale: scale)), 1)
    }

    /// The two bases agree to a few percent on a healthy pack. A glitched reading (a gauge that says 10 while the
    /// capacity says 100) must not turn Charge Control's limit into a tiny or an enormous target on the mAh basis, so
    /// the ratio is held to a sane band.
    func testTheGaugeRatioIsHeldToASaneBand() {
        let scale = pack()
        XCTAssertEqual(scale.gaugeRatio(skewed(gauge: 10, mAhPercent: 100, charging: false, scale: scale)), 0.8,
                       accuracy: 1e-9, "a glitched low gauge made the target tiny")
        XCTAssertEqual(scale.gaugeRatio(skewed(gauge: 100, mAhPercent: 20, charging: false, scale: scale)), 1.25,
                       accuracy: 1e-9, "a glitched high gauge made the target enormous")
        XCTAssertEqual(scale.gaugeRatio(skewed(gauge: 80, mAhPercent: 100, charging: false, scale: scale)), 0.8,
                       accuracy: 1e-9)
        XCTAssertEqual(scale.gaugeRatio(skewed(gauge: 100, mAhPercent: 80, charging: false, scale: scale)), 1.25,
                       accuracy: 1e-9)
        // Inside the band it is untouched.
        XCTAssertEqual(scale.gaugeRatio(skewed(gauge: 90, mAhPercent: 85, charging: false, scale: scale)), 90.0 / 85.0,
                       accuracy: 1e-9)
        XCTAssertEqual(scale.gaugeRatio(skewed(gauge: 80, mAhPercent: 76, charging: false, scale: scale)), 80.0 / 76.0,
                       accuracy: 1e-9)
    }

    // ── The monitor hands Charge Control's limit to the target ──────────────

    /// The closure is read once per tick, so the learner and the target are told
    /// the same thing, and not at all by anything that is not a tick.
    func testTheMonitorReadsChargeControlsLimitOncePerTick() throws {
        var reads = 0
        let m = try XCTUnwrap(PowerMonitor(scale: makeExactScale(),
                                           chargeControlLimit: { reads += 1; return 99 }))
        XCTAssertEqual(reads, 0)
        _ = m.tick(full: false, attribution: false)
        XCTAssertEqual(reads, 1)
        _ = m.tick(full: false, attribution: false)
        XCTAssertEqual(reads, 2)
    }

    func testTheMonitorPublishesChargeControlsLimitAsTheTarget() throws {
        // Non-nil, so the learner stands down and never writes the real defaults.
        let m = try XCTUnwrap(PowerMonitor(scale: makeExactScale(), chargeControlLimit: { 99 }))
        let snap = try XCTUnwrap(m.tick(full: false, attribution: false))
        guard let st = snap.state else { throw XCTSkip("no battery on this machine") }
        try XCTSkipIf(st.isCharging && st.percent >= 99, "charging past the limit takes the overshoot rule")

        let target = try XCTUnwrap(snap.chargeTarget)
        XCTAssertTrue(target.isLearnedLimit)
        XCTAssertEqual(target.percent * snap.scale.gaugeRatio(st), 99, accuracy: 1e-6,
                       "whatever was learned on this Mac, the target is Charge Control's 99")

        let none = try XCTUnwrap(PowerMonitor(scale: makeExactScale(), chargeControlLimit: { 100 }))
        let full = try XCTUnwrap(none.tick(full: false, attribution: false)?.chargeTarget)
        XCTAssertEqual(full, ChargeTarget.Level(percent: 100, isLearnedLimit: false))
    }

    // ── The command-line tool and Charge Control ────────────────────────────

    /// The tool has no Charge Control of its own, but the app's may be holding the battery below the Mac's own limit
    /// while the tool runs. Left at "off" the tool's learner took a hold of five minutes or more for a limit macOS
    /// enforces, and remembered it. The tool reads whether the app's Charge Control is on, and its limit, from the
    /// app's settings (the same domain `Settings` reads).
    func testTheCommandLineReadsTheAppsChargeControlFromItsSettings() throws {
        let (d, name) = try TestDefaults.make(owner: "CLICharge", test: self.name)
        defer { TestDefaults.destroy(d, name) }
        let app = Settings(defaults: d)

        XCTAssertNil(Settings.chargeControlLimit(in: d), "Charge Control is off by default")
        app.chargeControlEnabled = true
        app.chargeLimit = 90
        XCTAssertEqual(Settings.chargeControlLimit(in: d), 90)
        app.chargeLimit = 63
        XCTAssertEqual(Settings.chargeControlLimit(in: d), 63, "read at each tick, not once")
        app.chargeControlEnabled = false
        XCTAssertNil(Settings.chargeControlLimit(in: d))
        // Garbage in the plist (written by hand) is the same clamped number the app reads.
        d.set(1000, forKey: "anode." + Settings.Key.chargeLimit)
        app.chargeControlEnabled = true
        XCTAssertEqual(Settings.chargeControlLimit(in: d), Settings.chargeLimitRange.upperBound)
    }

    /// The tool's monitor passes that reading on, and stands its learner down while the app's Charge Control is on.
    func testTheCommandLineMonitorFollowsTheAppsChargeControl() throws {
        let (d, name) = try TestDefaults.make(owner: "CLICharge", test: self.name)
        defer { TestDefaults.destroy(d, name) }
        let app = Settings(defaults: d)
        app.chargeControlEnabled = true
        app.chargeLimit = 99
        let m = try XCTUnwrap(PowerMonitor.forCommandLine(scale: makeExactScale(), defaults: d, effectiveUID: 501))
        XCTAssertTrue(m.learnsChargeLimit, "a reading that can be trusted needs no blanket stand-down")
        let snap = try XCTUnwrap(m.tick(full: false, attribution: false))
        guard let st = snap.state else { throw XCTSkip("no battery on this machine") }
        try XCTSkipIf(st.isCharging && st.percent >= 99, "charging past the limit takes the overshoot rule")
        let target = try XCTUnwrap(snap.chargeTarget)
        XCTAssertTrue(target.isLearnedLimit)
        XCTAssertEqual(target.percent * snap.scale.gaugeRatio(st), 99, accuracy: 1e-6,
                       "the tool says what the app holds, not what an earlier run learned")
    }

    /// A tool that cannot read the app's settings reliably (run as root, it reads root's, not the person's; or no
    /// settings at all) learns nothing: a hold it cannot tell from the Mac's own limit is never remembered.
    func testTheCommandLineLearnsNothingWhereItCannotReadTheAppsSettings() throws {
        let (d, name) = try TestDefaults.make(owner: "CLICharge", test: self.name)
        defer { TestDefaults.destroy(d, name) }
        let asRoot = try XCTUnwrap(PowerMonitor.forCommandLine(scale: makeExactScale(), defaults: d, effectiveUID: 0))
        XCTAssertFalse(asRoot.learnsChargeLimit)
        let noStore = try XCTUnwrap(PowerMonitor.forCommandLine(scale: makeExactScale(), defaults: nil,
                                                                effectiveUID: 501))
        XCTAssertFalse(noStore.learnsChargeLimit)
        // The learner is stood down for a hold Charge Control is known to have, and for one that cannot be ruled out.
        XCTAssertTrue(PowerMonitor.learnerStandsDown(chargeControlLimit: 90, learnsChargeLimit: true))
        XCTAssertTrue(PowerMonitor.learnerStandsDown(chargeControlLimit: nil, learnsChargeLimit: false))
        XCTAssertTrue(PowerMonitor.learnerStandsDown(chargeControlLimit: 90, learnsChargeLimit: false))
        XCTAssertFalse(PowerMonitor.learnerStandsDown(chargeControlLimit: nil, learnsChargeLimit: true),
                       "with Charge Control off the Mac's own limit is still learned")
    }

    /// The limit is worth nothing if it is forgotten at quit: the app is normally
    /// launched into a machine already sitting at its limit, where there is no
    /// stop to observe. Same bargain `USBPowerTracker` makes with device costs.
    func testTheLimitIsRememberedAcrossLaunches() {
        let d = store()
        learn(ChargeLimitLearner(defaults: d), at: 80)
        XCTAssertEqual(ChargeLimitLearner(defaults: d).limit, 80)
    }

    /// Optimized Battery Charging holds at 80 % overnight and then charges on to
    /// full. That hold looks exactly like a limit while it lasts, so it is
    /// learned — and reaching FULL on the adapter is the proof that it was not
    /// one. A real limit never lets the gauge say `FullyCharged`.
    func testReachingFullOnTheAdapterForgetsALearnedLimit() {
        let d = store()
        let l = ChargeLimitLearner(defaults: d)
        learn(l, at: 80)
        XCTAssertEqual(l.limit, 80)

        let scale = pack()
        let full = Battery.State(percent: 100, isCharging: false, onAC: true,
                                 cycleCount: 21, voltage_mV: 12900, amperage_mA: 0,
                                 remainingCapacity_mAh: scale.fullChargeCapacity_mAh,
                                 timeRemaining_min: nil,
                                 notChargingReason: 0, fullyCharged: true)
        l.observe(full, percent: 100, at: Date(timeIntervalSinceReferenceDate: 9000))
        XCTAssertNil(l.limit, "a pack that reached full was never limited")
        XCTAssertNil(ChargeLimitLearner(defaults: d).limit, "and the next launch agrees")
        XCTAssertEqual(l.target(atPercent: 30, isCharging: true).percent, 100)
    }

    /// Holding at the limit is not full, so the limit survives it.
    func testHoldingAtTheLimitDoesNotForgetIt() {
        let l = ChargeLimitLearner(defaults: store())
        learn(l, at: 80)
        learn(l, at: 80)
        XCTAssertEqual(l.limit, 80)
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
            drain: nil, shared: nil)
        XCTAssertEqual(toLimit?.sourceLabel, "charging to 80% · estimated")
        // 20 points at 58.05 %/hr plus the taper is 21.5 min. The same headline
        // built against 100% reads 41m — the defect, in the one place it shows.
        XCTAssertEqual(toLimit?.headline, "21m")

        let toFull = GlanceCardView.model(
            from: snapshot(charging(at: 60, mA: 3600, scale: scale), scale: scale,
                           target: ChargeTarget.Level(percent: 100, isLearnedLimit: false)),
            drain: nil, shared: nil)
        XCTAssertEqual(toFull?.sourceLabel, "charging to full · estimated",
                       "no limit is known, so no percentage may be named")

        // Sitting at the limit: finished, not faulty.
        let held = GlanceCardView.model(
            from: snapshot(holding(at: 80, scale: scale), scale: scale,
                           target: ChargeTarget.Level(percent: 80, isLearnedLimit: true)),
            drain: nil, shared: nil)
        XCTAssertEqual(held?.sourceLabel, "held at 80% limit")

        let idle = GlanceCardView.model(
            from: snapshot(holding(at: 55, scale: scale), scale: scale,
                           target: ChargeTarget.Level(percent: 80, isLearnedLimit: true)),
            drain: nil, shared: nil)
        XCTAssertEqual(idle?.sourceLabel, "not charging")
    }
}
