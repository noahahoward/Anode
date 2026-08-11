import XCTest
@testable import PowerKit

/// Which signal is speaking, whether it reaches the screen, and the basis it
/// divides. The estimator has three tiers and they do not agree with each other by
/// accident; a user looking at "3h 40m" has to be able to tell a measured figure
/// from a modelled one.
final class DrainEstimateSourceTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let volts = 11_878.0
    /// This machine's pack, so the numbers in the assertions are the ones measured
    /// on it rather than round ones.
    private let scale = BatteryScale(fullChargeCapacity_mAh: 6193,
                                     designCapacity_mAh: 6249,
                                     nominalVoltage_V: BatteryScale.seedNominalVoltage_V,
                                     isCalibrated: true)

    /// Drives the estimator for `minutes` at `watts`, with the gauge's mAh field
    /// falling at `mAhPerMinute` — deliberately DECOUPLED from the wattage so a test
    /// can tell which of the two signals the answer came from.
    @discardableResult
    private func drive(_ est: DrainRateEstimator, minutes: Int, watts: Double,
                       mAhPerMinute: Double, startMAh: Double = 3667,
                       withAccumulator: Bool = true,
                       powerBased_pctHr: Double? = 8.0) -> Double {
        var acc: Int64 = -1_000_000
        var count: UInt64 = 500_000
        var mAh = startMAh
        var at = t0
        var awake = 10_000.0
        for m in 0...(minutes * 30) {          // one record every 2 s, as the app does
            if m > 0, m % 30 == 0 {            // a 60-tick batch every minute
                acc &-= Int64(watts * 1000 * 60)
                count &+= 60
                mAh -= mAhPerMinute
            }
            let d = withAccumulator
                ? BatteryDischargeTrend.Sample(accumulatedDischarge: acc, accumulatorCount: count,
                                               voltage_mV: volts, timestamp: at, awake: awake)
                : nil
            est.record(remainingCapacity_mAh: mAh, onAC: false, isCharging: false,
                       scale: scale, powerBased_pctHr: powerBased_pctHr,
                       discharge: d, at: at)
            at = at.addingTimeInterval(2)
            awake += 2
        }
        return mAh
    }

    // ── Tiering ─────────────────────────────────────────────────────────────

    /// The accumulator wins outright when it has a window. Set up so the two
    /// disagree: the gauge's mAh falls at 12 mAh/min (a ~7 %/hr story) while the
    /// accumulator integrates 6 W (505 mA, ~8.2 %/hr). Only one of them can be the
    /// published rate.
    func testTheDischargeAccumulatorOutranksTheGaugeRegression() {
        let est = DrainRateEstimator()
        drive(est, minutes: 40, watts: 6.0, mAhPerMinute: 12)
        let e = est.estimate()
        XCTAssertEqual(e?.source, .discharge)
        // 6000 mW / 11878 mV = 505.1 mA; against 6193 mAh that is 8.16 %/hr.
        XCTAssertEqual(e?.percentPerHour ?? 0, 505.1 / 6193 * 100, accuracy: 0.05)
        XCTAssertEqual(e?.confidence, 1)
    }

    /// No accumulator — an older machine, or a tick where the registry read failed.
    /// The regression carries it, and says so. This is the fallback the design is
    /// required to degrade to, not an error path.
    func testFallsBackToTheRegressionWithoutAnAccumulator() {
        let est = DrainRateEstimator()
        drive(est, minutes: 40, watts: 6.0, mAhPerMinute: 12, withAccumulator: false)
        let e = est.estimate()
        XCTAssertNotNil(e)
        XCTAssertNotEqual(e?.source, .discharge)
        // 12 mAh/min = 720 mAh/hr against 6193 mAh = 11.6 %/hr.
        XCTAssertEqual(e?.percentPerHour ?? 0, 11.6, accuracy: 1.5)
    }

    /// An accumulator that has been reset is not a slow discharge. The trend must
    /// hand back nothing and let the regression answer, rather than publish a
    /// figure derived from a counter discontinuity.
    func testFallsBackWhenTheAccumulatorIsImplausible() {
        let est = DrainRateEstimator()
        var at = t0, awake = 10_000.0, mAh = 3667.0
        var count: UInt64 = 500_000
        for m in 0...(40 * 30) {
            // The counter is pinned at zero: every window is non-discharging.
            if m > 0, m % 30 == 0 { count &+= 60; mAh -= 12 }
            est.record(remainingCapacity_mAh: mAh, onAC: false, isCharging: false,
                       scale: scale, powerBased_pctHr: 8.0,
                       discharge: BatteryDischargeTrend.Sample(
                           accumulatedDischarge: 0, accumulatorCount: count,
                           voltage_mV: volts, timestamp: at, awake: awake),
                       at: at)
            at = at.addingTimeInterval(2); awake += 2
        }
        XCTAssertNotEqual(est.estimate()?.source, .discharge)
        XCTAssertNotNil(est.estimate(), "the fallback must still answer")
    }

    /// Five minutes in, the accumulator has a window and takes over. Before that
    /// the answer is the power-based one, marked as such — never a fabricated
    /// number and never a blank where a real measurement exists.
    ///
    /// The floor moved from two minutes to five after a cold boot published 25 h
    /// and then 5 h a second later: a two-minute window is a third of one gauge
    /// publish, so one batch swung the answer by twenty hours. The tier ORDER is
    /// unchanged — measured discharge still outranks the power estimate — only
    /// the point at which the measured path is allowed to speak.
    func testTheMeasuredPathTakesOverOnceItHasAWindow() {
        let est = DrainRateEstimator()
        drive(est, minutes: 4, watts: 6.0, mAhPerMinute: 12)
        XCTAssertNotEqual(est.estimate()?.source, .discharge,
                          "four windows is still short of the floor")
        XCTAssertNotNil(est.estimate(), "and the power-based answer covers the gap")
        let est2 = DrainRateEstimator()
        drive(est2, minutes: 6, watts: 6.0, mAhPerMinute: 12)
        XCTAssertEqual(est2.estimate()?.source, .discharge)
    }

    // ── One basis, one arithmetic ───────────────────────────────────────────

    /// The published rate and the published time are the same claim. Whatever else
    /// changes, charge ÷ rate must be the time printed beside it: they used to be
    /// computed twice and disagreed by a factor of two on screen.
    func testTheRateAndTheTimeMultiplyOut() {
        let est = DrainRateEstimator()
        let endMAh = drive(est, minutes: 40, watts: 6.0, mAhPerMinute: 12)
        let e = est.estimate()!
        let chargePct = endMAh / scale.fullChargeCapacity_mAh * 100
        XCTAssertEqual((e.timeRemaining ?? 0) / 3600 * e.percentPerHour, chargePct,
                       accuracy: 0.01)
    }

    /// The basis change, stated as a test. The gauge publishes two answers to "how
    /// full is it" and they differ by 1-2 points on this machine; the projection
    /// divides the mAh one, which is the pessimistic and the correct one.
    func testChargePercentUsesTheMAhBasisAndIsLowerThanTheIntegerField() {
        let st = Battery.State(percent: 61, isCharging: false, onAC: false,
                               cycleCount: 20, voltage_mV: 11878, amperage_mA: -347,
                               remainingCapacity_mAh: 3667, timeRemaining_min: 636)
        // 3667 / 6193 = 59.21 %, against the gauge's own rounded 61 %.
        XCTAssertEqual(scale.chargePercent(st), 59.21, accuracy: 0.01)
        XCTAssertLessThan(scale.chargePercent(st), Double(st.percent),
                          "the integer field is the optimistic one — that is the point")
        // Live on this machine: one 60 s window read 4104.8 mW mean at 11878 mV,
        // which is 345.6 mA. On the mAh basis that projects 637 minutes and the
        // pack's own TimeRemaining said 636; on the integer basis, 656.
        let rate = 345.6 / 6193 * 100
        let mAhMin = DrainEstimate.timeToEmpty(chargePercent: scale.chargePercent(st),
                                               ratePctHr: rate)! / 60
        let intMin = DrainEstimate.timeToEmpty(chargePercent: Double(st.percent),
                                               ratePctHr: rate)! / 60
        XCTAssertEqual(mAhMin, 636, accuracy: 3)
        XCTAssertEqual(intMin - mAhMin, 19, accuracy: 3)
    }

    /// Hardware whose `BatteryData` this app has never seen publishes no mAh at
    /// all. Falling back to the integer percent is right; inventing a fraction is
    /// not.
    func testChargePercentFallsBackToTheIntegerFieldWithoutMAh() {
        let st = Battery.State(percent: 61, isCharging: false, onAC: false,
                               cycleCount: 20, voltage_mV: 11878, amperage_mA: -347,
                               remainingCapacity_mAh: 0, timeRemaining_min: nil)
        XCTAssertEqual(scale.chargePercent(st), 61)
    }

    func testTimeToEmptyRefusesWhatItCannotKnow() {
        // Not meaningfully draining. Stated at a charge low enough that the answer
        // would otherwise be plausible — 1 % at 0.05 %/hr is 20 hours, which the
        // 99-hour cap below would happily let through.
        XCTAssertNil(DrainEstimate.timeToEmpty(chargePercent: 1, ratePctHr: 0.05))
        XCTAssertNil(DrainEstimate.timeToEmpty(chargePercent: 60, ratePctHr: 0.05))
        // A fit through noise, not a runtime a laptop has.
        XCTAssertNil(DrainEstimate.timeToEmpty(chargePercent: 60, ratePctHr: 0.55))
        XCTAssertNil(DrainEstimate.timeToEmpty(chargePercent: 0, ratePctHr: 8))
        XCTAssertEqual(DrainEstimate.timeToEmpty(chargePercent: 60, ratePctHr: 6)! / 3600,
                       10, accuracy: 1e-9)
    }

    // ── Provenance reaching the screen ──────────────────────────────────────

    /// `windowSpan` defaults past `DrainEstimate.settleSeconds`, so the existing
    /// cases keep asking what they were asking: whether the MARKER is right. The
    /// separate question — whether there is enough history to quote a time at all
    /// — is `canQuoteTime`, and it has its own tests.
    private func registry(_ shared: (pctHr: Double, timeRemaining_hr: Double?,
                                     source: DrainEstimate.Source)?,
                          windowSpan: TimeInterval = 1800) -> MetricRegistry {
        let st = Battery.State(percent: 61, isCharging: false, onAC: false,
                               cycleCount: 20, voltage_mV: 11878, amperage_mA: -347,
                               remainingCapacity_mAh: 3667, timeRemaining_min: nil)
        let r = MetricRegistry()
        r.registerBatteryMetrics()
        r.update(with: PowerMonitor.Snapshot(
            drains: [], apps: [], systemApps: [], gpuApps: [], systemAttributionAge: nil,
            isFullSample: true, attributed_W: 0, rails: [], gpu_W: nil, fast_W: 0,
            measured_W: nil, measuredAge: nil, smoothed_W: 6, isCalibrated: true,
            smcTotal_W: 6, smcGain: 1, cpuRail_W: nil,
            display_W: nil, memory_W: nil, storage_W: nil, usb_W: nil,
            usbHasUnmeasured: false, usbHasRemembered: false, usbDevices: [],
            displayIsMeasured: false, baseline_W: nil, didJump: false,
            residual_W: 0, rawResidual_W: 0, scale: scale, state: st,
            coverage: 1, denied: 0, readable: 1, attempted: 1, interval: 2))
        r.update(displayedRate: shared.map { ($0.pctHr, $0.timeRemaining_hr,
                                              $0.source, windowSpan) })
        return r
    }

    /// The "*" the renderers draw means "inferred, not measured". A time projected
    /// from half an hour of measured discharge does not carry it; one projected
    /// from this instant's draw does. Without this the two are indistinguishable on
    /// screen, and the research found `source` reached nothing at all.
    /// A RATE can be measured. A TIME REMAINING cannot.
    ///
    /// This test previously asserted the opposite for time: that the "*" dropped
    /// when the rate came from the discharge accumulator. The rate is measured
    /// end to end — but the time extrapolates it across a future nobody has
    /// measured, and the future is where the error lives. An unmarked
    /// time-to-empty asserted that a prediction was a fact, in the one place this
    /// app must not: nobody reads a missing asterisk as "the rate behind this was
    /// measured", they read it as "this is known".
    ///
    /// The distinction is not lost, it moves to where words fit: the glance card
    /// prints "measured drain" / "estimated from draw" / "no estimate yet". The
    /// menu bar keeps the marker on `batteryDrain`, which is a rate, and that is
    /// what still makes the two tiers distinguishable there.
    func testTimeRemainingIsAlwaysAnEstimateButTheRateNeedNotBe() {
        let measured = registry((8.16, 7.25, .discharge))
        XCTAssertEqual(measured.value(for: .batteryTimeLeft)?.text, "7h 15m")
        XCTAssertTrue(measured.value(for: .batteryTimeLeft)?.isEstimate ?? false,
                      "a time remaining is a projection however well measured its rate")
        XCTAssertFalse(measured.value(for: .batteryDrain)?.isEstimate ?? true,
                       "the RATE is measured end to end, and still says so")

        let modelled = registry((8.16, 7.25, .power))
        XCTAssertEqual(modelled.value(for: .batteryTimeLeft)?.text, "7h 15m")
        XCTAssertTrue(modelled.value(for: .batteryTimeLeft)?.isEstimate ?? false)
        XCTAssertTrue(modelled.value(for: .batteryDrain)?.isEstimate ?? false,
                      "a rate inferred from instantaneous draw is an estimate")
    }

    /// Nothing published yet, and nothing else to fall back on: the widget shows
    /// "—" rather than a number nobody measured.
    func testNoSharedFigureAndNoFallbackShowsNothing() {
        let r = registry(nil)
        // `projectedRuntime_hr` still answers from the smoothed draw — that IS a
        // measurement — so this asserts the shared pair is not required to exist.
        XCTAssertNotNil(r.value(for: .batteryTimeLeft))
        XCTAssertTrue(r.value(for: .batteryTimeLeft)?.isEstimate ?? false)
    }

    /// `.insufficient` means nothing is known yet, so no time is shown — not even
    /// the widget's own projection from smoothed draw.
    ///
    /// This TIGHTENS what the test here used to assert. It used to let the widget
    /// fall back to `projectedRuntime_hr`, on the grounds that smoothed draw is a
    /// measurement. It is — and the RATE is still shown from it. The TIME is a
    /// different claim: charge ÷ an instantaneous rate, projected across the whole
    /// rest of the battery. Reported from the field, a machine unplugged while
    /// idle read "3 %/hr" beside "25 hours"; the rate was true and the time was
    /// not, because only one of them claimed to know about the future.
    ///
    /// The rate is unaffected and still carries its marker, which is the half this
    /// test was really about.
    func testAnInsufficientSharedFigureShowsNoTimeAtAll() {
        let r = registry((8.16, nil, .insufficient))
        XCTAssertNil(r.value(for: .batteryTimeLeft),
                     "a time was quoted with no history behind it")
        XCTAssertTrue(r.value(for: .batteryDrain)?.isEstimate ?? false,
                      "an insufficient-history rate is not a measured one")
    }

    /// The settle window, which is the case this exists for: the trend has just
    /// been reset by an unplug or a wake, so the figure is the instantaneous power
    /// tier with no window behind it.
    func testNoTimeIsQuotedInTheFirstMinutesAfterAnUnplug() {
        let justUnplugged = registry((3.0, 25.0, .power), windowSpan: 10)
        XCTAssertNil(justUnplugged.value(for: .batteryTimeLeft),
                     "quoted 25 hours from ten seconds of history")
        XCTAssertNotNil(justUnplugged.value(for: .batteryDrain),
                        "the RATE is a real reading and must still be shown")

        // And once there is history, the same tier is allowed to speak.
        let settled = registry((3.0, 25.0, .power), windowSpan: 600)
        XCTAssertNotNil(settled.value(for: .batteryTimeLeft))
    }

    /// A measured-discharge figure is never withheld: it is backed by an
    /// accumulated window by construction.
    func testAMeasuredFigureIsNeverWithheld() {
        XCTAssertTrue(DrainEstimate.canQuoteTime(source: .discharge, windowSpan: 0))
        XCTAssertTrue(DrainEstimate.canQuoteTime(source: .observed, windowSpan: 0))
        XCTAssertTrue(DrainEstimate.canQuoteTime(source: .blended, windowSpan: 0))
        XCTAssertFalse(DrainEstimate.canQuoteTime(source: .insufficient, windowSpan: 9999))
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// Carrying the trend across an app restart.
///
/// The battery does not know the app restarted. Without this the trend began
/// empty on every launch, so quitting and reopening threw away up to half an
/// hour of measured discharge and put the estimate back to "measuring" — which
/// is wrong, because nothing about the machine had changed. The three things
/// that SHOULD clear it are a reboot, a first-ever launch, and the adapter.
final class DischargeTrendPersistenceTests: XCTestCase {

    /// One sample per minute of steady discharge, as the hardware would publish
    /// it: the accumulator counts down at 1 Hz in 60-tick batches.
    private func samples(minutes: Int, mW: Double, from t0: Date = Date(timeIntervalSince1970: 1_000_000),
                         awake0: TimeInterval = 10_000)
        -> [BatteryDischargeTrend.Sample] {
        (0...minutes).map { i -> BatteryDischargeTrend.Sample in
            let seconds: Double = 60 * Double(i)
            let discharge: Int64 = Int64(-mW * seconds)
            let ticks: UInt64 = UInt64(60 * i)
            return BatteryDischargeTrend.Sample(
                accumulatedDischarge: discharge,
                accumulatorCount: ticks,
                voltage_mV: 11_800,
                timestamp: t0.addingTimeInterval(seconds),
                awake: awake0 + seconds)
        }
    }

    private func trend(_ s: [BatteryDischargeTrend.Sample]) -> BatteryDischargeTrend {
        let t = BatteryDischargeTrend()
        for x in s { t.record(x, onBattery: true) }
        return t
    }

    /// A saved trend comes back saying the same thing it said before.
    func testARestoredTrendReportsTheSameRate() throws {
        let original = trend(samples(minutes: 12, mW: 6000))
        let before = try XCTUnwrap(original.trend)

        let data = try JSONEncoder().encode(original.persisted())
        let decoded = try JSONDecoder().decode(BatteryDischargeTrend.Persisted.self, from: data)
        let restored = BatteryDischargeTrend()
        restored.restore(decoded)

        let after = try XCTUnwrap(restored.trend)
        XCTAssertEqual(after.power_mW, before.power_mW, accuracy: 0.001,
                       "a restart changed what the battery had been doing")
    }

    /// And it keeps measuring from where it was, rather than starting over: a
    /// sample recorded after the restart differences against the restored
    /// history, because the accumulator kept counting while nobody watched.
    func testMeasurementContinuesAcrossTheRestart() throws {
        let saved = trend(samples(minutes: 10, mW: 6000)).persisted()
        let restored = BatteryDischargeTrend()
        restored.restore(saved)

        // The app was closed for two minutes; the hardware counted through it.
        let next = BatteryDischargeTrend.Sample(
            accumulatedDischarge: Int64(-6000.0 * 60 * 12),
            accumulatorCount: 60 * 12,
            voltage_mV: 11_800,
            timestamp: Date(timeIntervalSince1970: 1_000_000 + 720),
            awake: 10_000 + 720)
        XCTAssertTrue(restored.record(next, onBattery: true),
                      "the restored trend refused a sample it should have accepted")
        XCTAssertEqual(try XCTUnwrap(restored.trend).power_mW, 6000, accuracy: 1)
    }

    /// TIME ON THE ADAPTER still clears it, restored or not. This is the guard
    /// that makes restoring safe: the app cannot know what happened while it was
    /// closed, so the arithmetic has to notice.
    func testGoingOnTheAdapterStillClearsARestoredTrend() throws {
        let restored = BatteryDischargeTrend()
        restored.restore(trend(samples(minutes: 10, mW: 6000)).persisted())
        restored.record(samples(minutes: 1, mW: 6000)[0], onBattery: false)
        XCTAssertNil(restored.trend, "adapter time survived into the trend")
    }

    /// A file from another format is ignored rather than decoded into something
    /// that looks plausible.
    func testAFileFromAnotherFormatIsIgnored() throws {
        let restored = BatteryDischargeTrend()
        restored.restore(trend(samples(minutes: 10, mW: 6000)).persisted())
        XCTAssertNotNil(restored.trend)

        let stale = BatteryDischargeTrend.Persisted(samples: [], version: 999)
        let other = BatteryDischargeTrend()
        other.restore(stale)
        XCTAssertNil(other.trend)
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// What the "still measuring" gate is allowed to key on.
///
/// It must mean NO HISTORY and nothing else. The first wiring zeroed the span
/// whenever the estimator's rate was distrusted — which happens whenever it and
/// the power figure disagree by more than 2x — so on a machine where those two
/// systematically disagree the estimate would have read "measuring" for as long
/// as the app ran, with hours of measurement behind it.
final class SettleGateTests: XCTestCase {

    func testAnAccumulatedWindowQuotesATimeWhicheverNumberWon() {
        // The power tier, which is what a distrusted estimator falls back to —
        // but with real history accumulated behind it.
        XCTAssertTrue(DrainEstimate.canQuoteTime(source: .power, windowSpan: 1800))
    }

    func testOnlyAnEmptyWindowReadsAsStillMeasuring() {
        XCTAssertFalse(DrainEstimate.canQuoteTime(source: .power, windowSpan: 0))
        XCTAssertFalse(DrainEstimate.canQuoteTime(source: .power,
                                                  windowSpan: DrainEstimate.settleSeconds - 1))
        XCTAssertTrue(DrainEstimate.canQuoteTime(source: .power,
                                                 windowSpan: DrainEstimate.settleSeconds))
    }

    /// The settle threshold is the same bar the trend itself sets before it will
    /// speak, so the two cannot disagree about when there is enough.
    func testTheThresholdMatchesTheTrendsOwnMinimum() {
        // `minTicks` is 120 ticks at 1 Hz.
        XCTAssertEqual(DrainEstimate.settleSeconds, 120)
    }
}
