import XCTest
@testable import PowerKit

/// The ledger bar is a PARTITION: its segments are shares of one total, so no
/// segment may be the whole of it while other things are also drawing power.
///
/// Under a sudden load the bar filled entirely with "apps" and the unattributable
/// segment disappeared. The cause is a time-constant mismatch, not a bad number:
/// `attributed_W` is rusage joules over the tick that just ended, while
/// `smoothed_W` is a median of fifteen PSTR reads, EWMA-smoothed and gain-corrected
/// against the gauge's 60 s mean, so for a few seconds after a step the parts
/// genuinely exceed the whole. Confirmed load-triggered: 88 passive ticks at idle
/// produced no overflow at all, worst raw residual 0.000.
///
/// The alarm that reports the impossible state is CORRECT and stays. What is fixed
/// is the bar asserting that apps explain the entire machine while it fires.
final class LedgerSpanTests: XCTestCase {

    private let scale = BatteryScale(fullChargeCapacity_mAh: 6193,
                                     designCapacity_mAh: 6249,
                                     nominalVoltage_V: BatteryScale.seedNominalVoltage_V,
                                     isCalibrated: true)

    private func snapshot(attributed: Double, smoothed: Double, cpuRail: Double?,
                          gpu: Double? = 0.8, display: Double? = 2.4,
                          memory: Double? = 0.6, storage: Double? = 0.3,
                          usb: Double? = nil,
                          isFullSample: Bool = true) -> PowerMonitor.Snapshot {
        PowerMonitor.Snapshot(
            drains: [], apps: [], systemApps: [], gpuApps: [],
            systemAttributionAge: nil, isFullSample: isFullSample,
            attributed_W: attributed, rails: [], gpu_W: gpu,
            fast_W: attributed + (gpu ?? 0), measured_W: nil, measuredAge: nil,
            smoothed_W: smoothed, isCalibrated: true,
            smcTotal_W: smoothed, smcGain: 1, cpuRail_W: cpuRail,
            display_W: display, memory_W: memory, storage_W: storage, usb_W: usb,
            usbHasUnmeasured: false, usbHasRemembered: false, usbDevices: [],
            displayIsMeasured: true, baseline_W: nil, didJump: false,
            residual_W: max(0, smoothed - attributed - (gpu ?? 0)),
            rawResidual_W: smoothed - attributed - (gpu ?? 0),
            scale: scale, state: nil,
            coverage: 0.63, denied: 296, readable: 504, attempted: 800, interval: 2)
    }

    /// What the bar actually lays out: every segment it draws, in the order it
    /// draws them. Apps and system processes together occupy `max(cpuRail,
    /// attributed)` because system processes are the clamped difference.
    private func segments(_ s: PowerMonitor.Snapshot) -> [Double] {
        [s.attributed_W,
         max(0, (s.cpuRail_W ?? 0) - s.attributed_W),
         s.gpu_W ?? 0, s.memory_W ?? 0, s.storage_W ?? 0, s.usb_W ?? 0,
         s.display_W ?? 0, s.platform_W ?? 0]
    }

    // ── The failure ─────────────────────────────────────────────────────────

    /// A load step: rusage has already seen 9 W of app energy while the smoothed
    /// total is still reporting the quiet machine at 7 W. Laid out against the
    /// smoothed figure, apps alone are 129 % of the bar and everything else is
    /// clipped off the end.
    func testAppsCannotFillTheWholeBarWhenAttributionOverflows() {
        let s = snapshot(attributed: 9.0, smoothed: 7.0, cpuRail: 3.2)
        XCTAssertTrue(s.hasAttributionOverflow, "the fixture must actually overflow")

        XCTAssertGreaterThan(s.attributed_W / s.smoothed_W, 1.0,
                             "this is the state the bar used to render as 100 % apps")
        XCTAssertLessThan(s.attributed_W / s.ledgerSpan_W, 1.0,
                          "apps must not be able to claim the whole machine")
        // Concretely: apps against the span the bar is drawn on.
        XCTAssertEqual(s.attributed_W / s.ledgerSpan_W, 9.0 / 13.1, accuracy: 1e-9)
    }

    /// The alarm is the point of the raw residual and must be untouched by any of
    /// this: it still measures the parts against the SMOOTHED total, which is the
    /// comparison that is physically impossible.
    func testTheOverflowAlarmStillFires() {
        let s = snapshot(attributed: 9.0, smoothed: 7.0, cpuRail: 3.2)
        XCTAssertTrue(s.hasAttributionOverflow)
        XCTAssertEqual(s.rawResidual_W, 7.0 - 9.0 - 0.8, accuracy: 1e-9,
                       "the signal is the unclamped residual and it is not clamped")
    }

    /// Conservation, which no fix here is allowed to weaken: the segments the bar
    /// draws sum to the span it draws them in, exactly, in overflow and out of it.
    /// The remainder is a segment, not a redistribution.
    func testSegmentsSumToTheSpanInBothStates() {
        for s in [snapshot(attributed: 9.0, smoothed: 7.0, cpuRail: 3.2),
                  snapshot(attributed: 1.2, smoothed: 11.0, cpuRail: 3.2)] {
            XCTAssertEqual(segments(s).reduce(0, +), s.ledgerSpan_W, accuracy: 1e-9)
        }
    }

    /// And the remainder is the one that gives way — it goes to zero, honestly,
    /// because in overflow there is genuinely nothing left over. No other segment
    /// is touched.
    func testTheRemainderGoesToZeroRatherThanAnySegmentBeingShrunk() {
        let s = snapshot(attributed: 9.0, smoothed: 7.0, cpuRail: 3.2)
        XCTAssertEqual(s.platform_W ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(s.attributed_W, 9.0, "the measured claim itself is not clamped")
        XCTAssertEqual(s.display_W, 2.4)
    }

    // ── The normal case: nothing changes ────────────────────────────────────

    /// 88 passive ticks at idle produced no overflow at all. On every such tick the
    /// span IS the smoothed total, to the bit — this must not quietly become a
    /// different headline number.
    func testAtIdleTheSpanIsExactlyTheSmoothedTotal() {
        let s = snapshot(attributed: 1.2, smoothed: 11.0, cpuRail: 3.2)
        XCTAssertFalse(s.hasAttributionOverflow)
        XCTAssertEqual(s.ledgerSpan_W, s.smoothed_W)
        XCTAssertEqual(s.ledgerSpan_pctHr, s.smoothed_pctHr)
    }

    /// Attribution can exceed the CPU RAIL without exceeding the total — the rail
    /// is itself a modelled share of PSTR. The apps segment is then wider than the
    /// rail, and the remainder has to be measured against the segment actually
    /// drawn or it prints watts the bar has already spent.
    func testTheRemainderAccountsForAppsExceedingTheCPURail() {
        let s = snapshot(attributed: 5.0, smoothed: 11.0, cpuRail: 3.2)
        XCTAssertFalse(s.hasAttributionOverflow)
        // 11 − (max(3.2, 5) + 0.8 + 0.6 + 0.3 + 2.4) = 1.9
        XCTAssertEqual(s.platform_W ?? -1, 1.9, accuracy: 1e-9)
        XCTAssertEqual(segments(s).reduce(0, +), s.ledgerSpan_W, accuracy: 1e-9)
    }

    /// A light tick claims nothing, so there is nothing to span: the claims are
    /// ABSENT rather than zero, and the span falls back to the total.
    func testALightTickClaimsNothing() {
        let s = snapshot(attributed: 0, smoothed: 9.0, cpuRail: nil,
                         gpu: nil, isFullSample: false)
        XCTAssertNil(s.claimed_W)
        XCTAssertNil(s.platform_W)
        XCTAssertEqual(s.ledgerSpan_W, s.smoothed_W)
    }

    /// Hardware with no readable CPU rail still gets a span that holds its parts.
    func testTheSpanHoldsTheClaimsWithoutACPURail() {
        let s = snapshot(attributed: 9.0, smoothed: 7.0, cpuRail: nil)
        XCTAssertGreaterThanOrEqual(s.ledgerSpan_W, s.claimed_W ?? 0)
        XCTAssertLessThan(s.attributed_W / s.ledgerSpan_W, 1.0)
    }
}
