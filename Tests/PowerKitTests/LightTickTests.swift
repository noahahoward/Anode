import XCTest
@testable import PowerKit

/// A light tick measures the whole machine and nothing per-process.
///
/// That made the two metrics whose entire job is stating how honest the
/// measurement is compute to exactly 1.0 and exactly 0 — rendered as "100%
/// unattributed" and "0% coverage", both with `isEstimate: false`, i.e. asserted
/// as measured fact on every tick the window spent hidden. A wrong number in a
/// power figure is a bug; a wrong number here is the app lying about how much to
/// trust every other number it shows.
final class LightTickHonestyTests: XCTestCase {

    private func monitor() throws -> PowerMonitor {
        // An explicit scale, so this runs on a machine with no battery too: the
        // question is what the sampler publishes, not what this Mac contains.
        try XCTUnwrap(PowerMonitor(scale: makeExactScale()))
    }

    // ── What the monitor publishes ──────────────────────────────────────────

    func testALightTickSaysItIsNotAFullSample() throws {
        let m = try monitor()
        let light = try XCTUnwrap(m.tick(full: false, attribution: false),
                                  "a light tick has nothing to diff and still always publishes")
        XCTAssertFalse(light.isFullSample)
    }

    /// Every quantity that is "measured minus attributed" has to be absent when
    /// the attribution step never ran. Computing it anyway does not produce an
    /// approximation, it produces the whole measurement wearing the residual's
    /// name.
    func testALightTickPublishesNoResidualAndNothingDerivedFromOne() throws {
        let m = try monitor()
        let light = try XCTUnwrap(m.tick(full: false, attribution: false))
        XCTAssertNil(light.residual_W)
        XCTAssertNil(light.residualShare, "this was exactly 1.0 — '100% unattributed'")
        XCTAssertNil(light.systemProcesses_W,
                     "the entire CPU rail is not anonymous daemon power just because nobody swept")
        XCTAssertNil(light.platform_W,
                     "the GPU rail is unread here, so the residue would swallow it")
    }

    func testAFullTickStillPublishesThem() throws {
        let m = try monitor()
        m.tick(full: true, attribution: false)   // prime: no prior sweep to diff against
        Thread.sleep(forTimeInterval: 0.2)
        let full = try XCTUnwrap(m.tick(full: true, attribution: false))
        XCTAssertTrue(full.isFullSample)
        XCTAssertNotNil(full.residual_W, "a full tick has an answer and must give it")
        XCTAssertGreaterThan(full.attempted, 0)
        XCTAssertGreaterThan(full.coverage, 0,
                             "a sweep that could read no process at all would be a different bug")
    }

    /// The calibrator fits fast-signal against gas-gauge over a publish window. A
    /// light tick's fast figure is 0 because nothing was sampled, not because
    /// nothing was drawing, and observing (fast: 0, slow: 5 W) fits the line
    /// through a point that was never measured.
    func testTheCalibratorIsGivenNothingByALightTick() throws {
        let m = try monitor()
        m.tick(full: true, attribution: false)   // prime: returns nil before sampling anything
        let before = m.accumulators.fastSincePublish
        m.tick(full: false, attribution: false)
        XCTAssertEqual(m.accumulators.fastSincePublish, before,
                       "a light tick contributed an invented 0 W to the calibration")
        Thread.sleep(forTimeInterval: 0.05)
        m.tick(full: true, attribution: false)
        XCTAssertEqual(m.accumulators.fastSincePublish, before + 1,
                       "a full tick's fast figure is a measurement and must still be observed")
    }

    // ── What the metrics render ─────────────────────────────────────────────

    private func registry(_ s: PowerMonitor.Snapshot) -> MetricRegistry {
        let r = MetricRegistry()
        r.registerBatteryMetrics()
        r.update(with: s)
        return r
    }

    func testUnattributedShareRendersAsNothingOnALightTick() {
        let light = makeLightTickSnapshot()
        // The fixture is the pre-fix shape on purpose, so the provider is tested
        // against the values that actually reached it: the arithmetic still
        // resolves, and what it resolves to is the falsehood.
        XCTAssertEqual(light.residual_W! / light.smoothed_W, 1.0, accuracy: 1e-12)
        XCTAssertNil(registry(light).value(for: .unattributedShare),
                     "'100% unattributed' was displayed for a tick that attributed nothing")
    }

    func testUnattributedShareStillRendersOnAFullTick() {
        let v = registry(makeFullTickSnapshot()).value(for: .unattributedShare)
        XCTAssertEqual(v?.value ?? 0, 0.7, accuracy: 1e-12)
        XCTAssertEqual(v?.text, "70%")
        XCTAssertTrue(v?.isEstimate ?? false, "it is derived from the smoothed total")
    }

    func testProcessCoverageRendersAsNothingOnALightTick() {
        let light = makeLightTickSnapshot()
        XCTAssertEqual(light.coverage, 0, "the zero that was being rendered as '0%'")
        XCTAssertNil(registry(light).value(for: .processCoverage),
                     "'we can see 0% of your processes' is a claim nothing measured")
    }

    func testProcessCoverageStillRendersOnAFullTick() {
        let v = registry(makeFullTickSnapshot()).value(for: .processCoverage)
        XCTAssertEqual(v?.text, "63%")
        XCTAssertFalse(v?.isEstimate ?? true, "coverage is counted, not estimated")
    }

    /// The correction must not overshoot. A light tick measures the whole machine
    /// perfectly well — that is the entire reason it exists — so the menu bar's
    /// headline figures have to survive it. Blanking those would trade one wrong
    /// answer for a widget that says "—" whenever the window is closed.
    func testTheWholeMachineMetricsAreUnaffectedByALightTick() {
        let r = registry(makeLightTickSnapshot())
        // 10 W against the exact scale (3600 J/%) is 10 %/hr.
        XCTAssertEqual(r.value(for: .batteryDrain)?.value ?? 0, 10, accuracy: 1e-12)
        XCTAssertEqual(r.value(for: .batteryPercent)?.value ?? 0, 50, accuracy: 1e-12)
        XCTAssertNotNil(r.value(for: .batteryTimeLeft))
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// Snapshots shaped exactly as `PowerMonitor.tick` built them BEFORE the fix, so
/// the providers are exercised against the numbers that were really reaching
/// them. Handing the light one a nil residual here would make these tests pass on
/// the strength of the fixture rather than the fix.
private func makeLightTickSnapshot() -> PowerMonitor.Snapshot {
    makeSnapshot(isFullSample: false, attributed: 0, gpu: nil,
                 residual: 10, coverage: 0, attempted: 0, readable: 0)
}

private func makeFullTickSnapshot() -> PowerMonitor.Snapshot {
    makeSnapshot(isFullSample: true, attributed: 2, gpu: 1,
                 residual: 7, coverage: 0.63, attempted: 800, readable: 504)
}

private func makeSnapshot(isFullSample: Bool, attributed: Double, gpu: Double?,
                          residual: Double, coverage: Double,
                          attempted: Int, readable: Int) -> PowerMonitor.Snapshot {
    let state = Battery.State(percent: 50, isCharging: false, onAC: false,
                              cycleCount: 100, voltage_mV: 11580,
                              amperage_mA: -500, remainingCapacity_mAh: 3000,
                              timeRemaining_min: nil)
    return PowerMonitor.Snapshot(
        drains: [], apps: [], systemApps: [], gpuApps: [],
        systemAttributionAge: nil,
        isFullSample: isFullSample,
        attributed_W: attributed, rails: [], gpu_W: gpu,
        fast_W: attributed + (gpu ?? 0),
        measured_W: nil, measuredAge: nil,
        smoothed_W: 10, isCalibrated: true,
        smcTotal_W: 10, smcGain: 1, cpuRail_W: 4,
        display_W: nil, memory_W: nil, storage_W: nil, usb_W: nil,
        usbHasUnmeasured: false, usbHasRemembered: false, usbDevices: [],
        displayIsMeasured: false, baseline_W: nil, didJump: false,
        residual_W: residual, rawResidual_W: residual,
        scale: makeExactScale(), state: state,
        coverage: coverage, denied: attempted - readable,
        readable: readable, attempted: attempted, interval: 2)
}
