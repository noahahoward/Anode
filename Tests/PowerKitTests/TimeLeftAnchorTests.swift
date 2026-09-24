import XCTest
@testable import PowerKit
@testable import AnodeApp

/// `reconciledRate` publishes an ANCHOR, and when it re-stamps that anchor's
/// instant is the whole design.
///
/// The projection in `DisplayedRate` is correct arithmetic in isolation and
/// still buys nothing if the instant it measures from is refreshed on every
/// call. This function runs every tick — 2 s visible, 8 s hidden — while the
/// gauge publishes a new charge about once a minute. An anchor re-stamped each
/// tick always has ~0 elapsed against it, so the headline would sit exactly as
/// still as it did before the change, with more machinery behind it.
///
/// These tests exist because that failure is invisible: every unit test of the
/// projector passes, the app compiles, and the number on screen does not move.
final class TimeLeftAnchorTests: XCTestCase {

    private func pack() -> BatteryScale {
        BatteryScale(fullChargeCapacity_mAh: 6197, designCapacity_mAh: 6251,
                     nominalVoltage_V: BatteryScale.seedNominalVoltage_V,
                     isCalibrated: false)
    }

    /// `remainingCapacity_mAh` is what the charge basis is computed from, so it
    /// is the knob these tests turn to simulate a gauge publish.
    private func draining(mAh: Double) -> Battery.State {
        Battery.State(percent: 61, isCharging: false, onAC: false, cycleCount: 20,
                      voltage_mV: 11878, amperage_mA: -347,
                      remainingCapacity_mAh: mAh, timeRemaining_min: nil)
    }

    private func snapshot(_ state: Battery.State, watts: Double = 8) -> PowerMonitor.Snapshot {
        PowerMonitor.Snapshot(
            drains: [], apps: [], systemApps: [], gpuApps: [],
            systemAttributionAge: nil, isFullSample: true,
            attributed_W: 0, rails: [], gpu_W: nil, fast_W: 0,
            measured_W: nil, measuredAge: nil, smoothed_W: watts, isCalibrated: true,
            smcTotal_W: watts, smcGain: 1, cpuRail_W: nil,
            display_W: nil, memory_W: nil, storage_W: nil, usb_W: nil,
            usbHasUnmeasured: false, usbHasRemembered: false, usbDevices: [],
            displayIsMeasured: false, baseline_W: nil, didJump: false,
            residual_W: 0, rawResidual_W: 0,
            scale: pack(), state: state,
            coverage: 1, denied: 0, readable: 1, attempted: 1, interval: 2)
    }

    private func estimate(_ charge: Double, rate: Double) -> DrainEstimate {
        DrainEstimate(percentPerHour: rate,
                      timeRemaining: DrainEstimate.timeToEmpty(chargePercent: charge,
                                                               ratePctHr: rate),
                      chargePercent: charge, confidence: 1, source: .discharge,
                      windowSpan: 1800, sampleCount: 30)
    }

    // ── THE test ─────────────────────────────────────────────────────────────

    /// Thirty ticks at 2 s with no new gauge publish. The gauge is silent, so the
    /// charge and the rate are unchanged on every one of them — and the displayed
    /// time must nevertheless be a minute lower at the end.
    ///
    /// This is the user-visible complaint, reproduced end to end: "it's been at
    /// 7:03 for more than a min."
    func testTheDisplayedTimeFallsWhileTheGaugeIsSilent() {
        let est = estimate(59.2, rate: 8.16)
        let snap = snapshot(draining(mAh: 3667))
        var anchor: DisplayedRate?
        var readings: [Double] = []
        for tick in 0...30 {
            let awake = 1000 + Double(tick) * 2
            anchor = AppDelegate.reconciledRate(snap, est, previous: anchor, awake: awake)
            readings.append(anchor!.timeRemaining_hr(now: awake)!)
        }
        XCTAssertEqual((readings.first! - readings.last!) * 3600, 60, accuracy: 1e-6,
                       "sixty seconds of silence must cost the estimate sixty seconds")
        // Strictly decreasing, not merely lower at the end.
        for (a, b) in zip(readings, readings.dropFirst()) {
            XCTAssertGreaterThan(a, b, "every tick must move the number")
        }
    }

    /// The same run, at the rendering the user actually sees. The old behaviour
    /// held one string for the whole minute; the fix must cross a minute boundary.
    func testTheRenderedStringChangesWithinAMinute() {
        let est = estimate(59.2, rate: 8.16)
        let snap = snapshot(draining(mAh: 3667))
        var anchor: DisplayedRate?
        var rendered: Set<String> = []
        for tick in 0...30 {
            let awake = 1000 + Double(tick) * 2
            anchor = AppDelegate.reconciledRate(snap, est, previous: anchor, awake: awake)
            let hr = anchor!.timeRemaining_hr(now: awake)!
            rendered.insert(MetricUnit.minutes.format((hr * 60).rounded()))
        }
        XCTAssertGreaterThan(rendered.count, 1,
                             "the headline was reported stuck at one string for over a "
                             + "minute; one string across 60 s is that bug")
    }

    // ── The re-stamp rule ────────────────────────────────────────────────────

    /// A new gauge publish re-anchors. The charge moved, so the elapsed clock
    /// starts again from it — otherwise the projection would keep subtracting
    /// time that the new reading has already accounted for, and double-count.
    func testANewPublishReAnchors() {
        let snap = snapshot(draining(mAh: 3667))
        let first = AppDelegate.reconciledRate(snap, estimate(59.2, rate: 8.16),
                                               previous: nil, awake: 1000)
        let held = AppDelegate.reconciledRate(snap, estimate(59.2, rate: 8.16),
                                              previous: first, awake: 1060)
        XCTAssertEqual(held.anchorAwake, 1000, "no publish, no re-anchor")

        let published = AppDelegate.reconciledRate(snap, estimate(59.0, rate: 8.16),
                                                   previous: held, awake: 1060)
        XCTAssertEqual(published.anchorAwake, 1060, "a new charge re-anchors")
        XCTAssertEqual(published.chargePercent, 59.0)
    }

    /// A rate change WITHOUT a publish must not re-anchor.
    ///
    /// Deliberate, and the opposite of what "the inputs changed, so re-stamp"
    /// would give. On the power tier the rate moves every tick while the charge
    /// does not; applying the new rate from the old charge reading charges the
    /// elapsed seconds at what the machine is doing now, where re-stamping would
    /// silently forgive them.
    func testARateChangeAloneDoesNotReAnchor() {
        let snap = snapshot(draining(mAh: 3667))
        let first = AppDelegate.reconciledRate(snap, estimate(59.2, rate: 8.16),
                                               previous: nil, awake: 1000)
        let faster = AppDelegate.reconciledRate(snap, estimate(59.2, rate: 12.0),
                                                previous: first, awake: 1060)
        XCTAssertEqual(faster.anchorAwake, 1000)
        XCTAssertEqual(faster.pctHr, 12.0)
        // The anchor's own corrected time, one minute later. Held at the
        // anchor's charge and re-quoted at the NEW rate, then counted down —
        // see `DrainEstimate.projected` for why this subtracts rather than
        // re-evaluating against a reduced charge.
        XCTAssertEqual(faster.timeRemaining_hr(now: 1060)!,
                       DrainEstimate.timeToEmpty(chargePercent: 59.2, ratePctHr: 12.0)!
                           / 3600 - 60.0 / 3600,
                       accuracy: 1e-9)
    }

    /// Going on AC drops the charge, so there is nothing to project and nothing
    /// to anchor. The renderers show "AC", not a stale countdown.
    func testOnACThereIsNoAnchor() {
        let ac = Battery.State(percent: 61, isCharging: false, onAC: true, cycleCount: 20,
                               voltage_mV: 11878, amperage_mA: 0,
                               remainingCapacity_mAh: 3667, timeRemaining_min: nil)
        let published = AppDelegate.reconciledRate(snapshot(ac), nil,
                                                   previous: nil, awake: 1000)
        XCTAssertNil(published.chargePercent)
        XCTAssertNil(published.timeRemaining_hr(now: 1200))
    }

    /// An anchor stamped in the future — a restored value, or a clock nobody
    /// should trust — is replaced rather than projected backwards, which would
    /// otherwise ADD runtime to the pack.
    func testAnAnchorFromTheFutureIsDiscarded() {
        let snap = snapshot(draining(mAh: 3667))
        let bogus = DisplayedRate(pctHr: 8.16, chargePercent: 59.2, anchorAwake: 9_999,
                                  source: .discharge, windowSpan: 1800)
        let fixed = AppDelegate.reconciledRate(snap, estimate(59.2, rate: 8.16),
                                               previous: bogus, awake: 1000)
        XCTAssertEqual(fixed.anchorAwake, 1000)
        XCTAssertEqual(fixed.timeRemaining_hr(now: 1000)!,
                       DrainEstimate.timeToEmpty(chargePercent: 59.2, ratePctHr: 8.16)! / 3600,
                       accuracy: 1e-9)
    }

    /// The publish-instant value is untouched by the whole change. Every metric
    /// the sweep harness scores is sampled at a publish, so this is what makes
    /// "the sweep numbers are unchanged" a regression guard rather than a
    /// tolerance.
    func testAtThePublishInstantNothingMoved() {
        let est = estimate(59.2, rate: 8.16)
        let published = AppDelegate.reconciledRate(snapshot(draining(mAh: 3667)), est,
                                                   previous: nil, awake: 1000)
        XCTAssertEqual(published.timeRemaining_hr(now: 1000)!,
                       est.timeRemaining! / 3600, accuracy: 1e-12)
    }
}
