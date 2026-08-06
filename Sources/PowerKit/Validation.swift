import Foundation

/// Ground-truth harness for the power model.
///
/// The battery is the only ground truth we have. Over a long enough on-battery
/// window the energy that LEFT THE PACK is knowable independently of every model
/// in this codebase:
///
///     E_actual [J] = deltaRemainingCapacity_mAh / 1000 * V_nom * 3600
///
/// and the model claims a total over the same window:
///
///     E_model [J] = ∫ smoothed_W dt        (trapezoidal, real tick intervals)
///
/// If the two disagree by more than ~10% the model is wrong and the app is lying.
/// The harness also checks the internal ledger invariant on every tick:
///
///     attributed_W + gpu_W + residual_W == smoothed_W    (within rounding)
///
/// HONESTY NOTE about that invariant in the current Monitor.swift: `residual_W`
/// is DEFINED as `max(0, smoothed - attributed - gpu)`, so the equation holds by
/// construction whenever the raw difference is non-negative — it is a tautology,
/// not a measurement. The one case where it carries information is when the clamp
/// fires: attributed + gpu exceeded the displayed total (double counting between
/// rusage CPU joules and the IOReport GPU rail, or the instantaneous `attributed`
/// spiking above the lagging EWMA `smoothed`). The published residual can never
/// go negative, so this harness recomputes the RAW residual itself and counts
/// those clamped ticks — they surface here as BOTH a ledger violation (the
/// published rows over-sum the total) and a negative residual.
///
/// TIMING TRAP, measured on this hardware: `RemainingCapacity` has 1 mAh
/// resolution (0.016% of the pack) but updates in ~60 s batches — five reads over
/// 20 s all return the same value. A naive first-to-last delta therefore carries
/// up to ~60 s of edge slop on each side. The harness aligns the validation
/// window to observed GAUGE CHANGE POINTS: the ratio is only computed between the
/// first and last tick where `RemainingCapacity` was seen to move, which cuts the
/// edge uncertainty from ~60 s to one tick interval.
public struct ValidationRun {
    public let started: Date
    public let ended: Date
    public let onBatteryThroughout: Bool
    /// Energy that left the pack, from the gas gauge. MEASURED.
    public let actualEnergy_J: Double
    /// ∫ smoothed_W dt — what the app displayed over the window. ESTIMATE under test.
    public let modelEnergy_J: Double
    /// ∫ attributed_W dt — the part explained by visible process rows.
    public let attributedEnergy_J: Double
    /// model / actual. 1.0 is perfect; outside 0.90…1.10 the model fails.
    public let ratio: Double
    /// Ticks where attributed + gpu + published residual ≠ smoothed (beyond rounding).
    public let ledgerViolations: Int
    public let maxLedgerError_W: Double
    /// Ticks where the RAW residual (smoothed − attributed − gpu) was negative,
    /// i.e. we attributed more power than we displayed — a double-counting signal
    /// the published (clamped) residual hides.
    public let negativeResiduals: Int
    /// Samples inside the gauge-aligned window the ratio was computed over.
    public let samples: Int
    /// Gauge movement inside the window. 1 mAh resolution bounds the quantisation
    /// error of `ratio` at roughly 2/delta — printed so small windows read as noisy.
    public let actualDelta_mAh: Double

    public static let passBand: ClosedRange<Double> = 0.90...1.10

    public var passed: Bool {
        onBatteryThroughout
            && ValidationRun.passBand.contains(ratio)
            && ledgerViolations == 0
            && negativeResiduals == 0
    }

    public var verdict: String {
        let span = ended.timeIntervalSince(started)
        let dur = String(format: "%dm %02ds", Int(span) / 60, Int(span) % 60)
        let ratioOK = ValidationRun.passBand.contains(ratio)
        var lines: [String] = []
        lines.append(passed ? "VERDICT: PASS" : "VERDICT: FAIL")
        lines.append(String(format: "  window       %@ on battery, %d samples (gauge-change aligned)", dur, samples))
        lines.append(String(format: "  actual       %.0f J  (%.0f mAh from the gas gauge — MEASURED, ±%.0f%% quantisation)",
                            actualEnergy_J, actualDelta_mAh,
                            actualDelta_mAh > 0 ? 200.0 / actualDelta_mAh : 0))
        lines.append(String(format: "  model        %.0f J  (∫ displayed smoothed total — the ESTIMATE under test)",
                            modelEnergy_J))
        lines.append(String(format: "  ratio        %.3f  model/actual  [pass band %.2f–%.2f] %@",
                            ratio, ValidationRun.passBand.lowerBound, ValidationRun.passBand.upperBound,
                            ratioOK ? "OK" : "OUT OF BAND"))
        lines.append(String(format: "  attributed   %.0f J  = %.0f%% of actual — process-table coverage",
                            attributedEnergy_J,
                            actualEnergy_J > 0 ? attributedEnergy_J / actualEnergy_J * 100 : 0))
        lines.append(String(format: "  ledger       %d violation(s), max error %.3f W, %d negative residual(s) %@",
                            ledgerViolations, maxLedgerError_W, negativeResiduals,
                            (ledgerViolations == 0 && negativeResiduals == 0) ? "OK" : "BROKEN"))
        if !onBatteryThroughout {
            lines.append("  NOTE: window was not on battery throughout — ratio is meaningless")
        }
        return lines.joined(separator: "\n")
    }
}

/// Accumulates PowerMonitor snapshots while on battery and, once enough gauge
/// movement has been observed, compares the model's integrated energy against the
/// pack's measured discharge.
///
/// Fail-soft rules, in keeping with the rest of PowerKit:
///   - Going on AC ABORTS the run (samples cleared, reason recorded). A discharge
///     ratio across a charging interval is not "approximately right", it is
///     meaningless, so we refuse to produce one.
///   - An unreadable battery state also aborts: without it we can neither confirm
///     on-battery nor read the gauge, and guessing would defeat the whole point.
///   - A gap of more than `maxGap_s` between ticks (sleep, suspended process)
///     aborts: trapezoidal integration across a sleep gap would credit the model
///     with energy nobody measured.
///   - `result()` returns nil — never a premature number — until the aligned
///     window spans `minimumSeconds`. `status` says what it is waiting for.
public final class ModelValidator {

    private struct Sample {
        let t: Date
        let smoothed_W: Double
        let attributed_W: Double
        let gpu_W: Double            // 0 when the rail was unavailable, as Monitor treats it
        let publishedResidual_W: Double?
        let mAh: Double
    }

    private let scale: BatteryScale
    private var store: [Sample] = []
    private var ledgerViolations = 0
    private var maxLedgerError_W = 0.0
    private var negativeResiduals = 0

    /// Why the last run was thrown away, if one was. Cleared by `reset()`.
    public private(set) var lastAbortReason: String?

    /// Ledger arithmetic tolerance. The snapshot fields are Doubles computed from
    /// each other, so genuine rounding error is ~1e-12 W; 1 mW is generous slack
    /// that still catches any real inconsistency.
    public static let ledgerTolerance_W = 0.001
    /// Ticks are ~5 s; anything beyond this is a sleep/suspend discontinuity.
    public static let maxGap_s: TimeInterval = 120

    public init(scale: BatteryScale) {
        self.scale = scale
    }

    // ── Recording ───────────────────────────────────────────────────────────

    public func record(_ snapshot: PowerMonitor.Snapshot, at now: Date = Date()) {
        guard let st = snapshot.state else {
            abort("battery state unreadable — cannot confirm on-battery")
            return
        }
        guard !st.onAC else {
            abort("machine went on AC")
            return
        }
        guard st.remainingCapacity_mAh > 0 else {
            abort("gauge RemainingCapacity read 0 — cannot integrate against it")
            return
        }
        if let last = store.last {
            let dt = now.timeIntervalSince(last.t)
            if dt <= 0 { return }  // clock stepped backwards or duplicate tick — drop it
            if dt > ModelValidator.maxGap_s {
                // Discontinuity (sleep). The old run is unusable; this sample seeds a new one.
                abort(String(format: "%.0f s gap between ticks (sleep?)", dt))
            }
        }

        // Per-tick ledger checks. These need no gauge, so they run on every sample.
        let gpu = snapshot.gpu_W ?? 0
        // RAW residual — recomputed here because the published one is clamped at 0.
        let raw = snapshot.smoothed_W - snapshot.attributed_W - gpu
        if raw < -ModelValidator.ledgerTolerance_W { negativeResiduals += 1 }
        if let res = snapshot.residual_W {
            let err = snapshot.attributed_W + gpu + res - snapshot.smoothed_W
            if abs(err) > ModelValidator.ledgerTolerance_W {
                ledgerViolations += 1
                maxLedgerError_W = max(maxLedgerError_W, abs(err))
            }
        }
        // A nil residual makes no ledger claim, so there is nothing to check.

        store.append(Sample(t: now,
                            smoothed_W: snapshot.smoothed_W,
                            attributed_W: snapshot.attributed_W,
                            gpu_W: gpu,
                            publishedResidual_W: snapshot.residual_W,
                            mAh: st.remainingCapacity_mAh))
    }

    /// Per-tick ledger error of a snapshot against its own published rows, for
    /// live display. nil when the snapshot published no residual.
    public static func ledgerError_W(of snapshot: PowerMonitor.Snapshot) -> Double? {
        guard let res = snapshot.residual_W else { return nil }
        return snapshot.attributed_W + (snapshot.gpu_W ?? 0) + res - snapshot.smoothed_W
    }

    private func abort(_ reason: String) {
        if !store.isEmpty || lastAbortReason == nil { lastAbortReason = reason }
        store.removeAll()
        ledgerViolations = 0
        maxLedgerError_W = 0
        negativeResiduals = 0
    }

    public func reset() {
        abort("reset")
        lastAbortReason = nil
    }

    // ── Results ─────────────────────────────────────────────────────────────

    /// nil until enough on-battery time has accumulated INSIDE the gauge-aligned
    /// window to be meaningful. Reporting success early would be worse than
    /// reporting nothing, so every guard here returns nil rather than a guess.
    public func result(minimumSeconds: TimeInterval = 900) -> ValidationRun? {
        compute(minimumSeconds: minimumSeconds)
    }

    /// Provisional model/actual ratio for live display. Same arithmetic as
    /// `result()` but without the minimum-duration gate — callers must label it
    /// provisional, never as a verdict.
    public func runningRatio() -> Double? {
        compute(minimumSeconds: nil)?.ratio
    }

    /// What the validator is currently waiting for, in plain words.
    public var status: String {
        if let reason = lastAbortReason, store.isEmpty {
            return "run aborted: \(reason) — accumulation restarted from zero"
        }
        guard let first = store.first, let last = store.last, store.count >= 2 else {
            return "no on-battery samples yet"
        }
        let span = last.t.timeIntervalSince(first.t)
        let changes = gaugeChangeIndices()
        if changes.count < 2 {
            return String(format: "%.0f s recorded; waiting for the gauge to move twice (seen %d change(s)) — it publishes ~every 60 s",
                          span, changes.count)
        }
        let aligned = store[changes.last!].t.timeIntervalSince(store[changes.first!].t)
        return String(format: "%.0f s recorded, %.0f s gauge-aligned", span, aligned)
    }

    public var sampleCount: Int { store.count }

    private func gaugeChangeIndices() -> [Int] {
        var out: [Int] = []
        guard store.count >= 2 else { return out }
        for i in 1..<store.count where store[i].mAh != store[i - 1].mAh {
            out.append(i)
        }
        return out
    }

    private func compute(minimumSeconds: TimeInterval?) -> ValidationRun? {
        guard store.count >= 2 else { return nil }
        let changes = gaugeChangeIndices()
        // Two observed gauge movements bound a window whose discharge is known to
        // 1 mAh with only one tick of edge slop. Fewer than two and the actual
        // energy is unknowable — refuse.
        guard let a = changes.first, let b = changes.last, b > a else { return nil }

        let alignedSpan = store[b].t.timeIntervalSince(store[a].t)
        if let minS = minimumSeconds, alignedSpan < minS { return nil }

        let delta_mAh = store[a].mAh - store[b].mAh
        // On battery throughout, capacity must fall. A non-positive delta means
        // the gauge did something we do not understand — refuse, never invert.
        guard delta_mAh > 0 else { return nil }

        // E = mAh/1000 * V_nom * 3600. Uses the scale's voltage so the harness
        // judges the model against the same energy scale the app displays with.
        let actual_J = delta_mAh / 1000 * scale.nominalVoltage_V * 3600

        // Trapezoidal integration over the REAL tick intervals — sampling runs on
        // a background queue and drifts, so dt is never assumed uniform.
        var model_J = 0.0
        var attributed_J = 0.0
        for i in (a + 1)...b {
            let dt = store[i].t.timeIntervalSince(store[i - 1].t)
            model_J += (store[i].smoothed_W + store[i - 1].smoothed_W) / 2 * dt
            attributed_J += (store[i].attributed_W + store[i - 1].attributed_W) / 2 * dt
        }

        return ValidationRun(started: store[a].t,
                             ended: store[b].t,
                             onBatteryThroughout: true,  // AC samples abort before storage
                             actualEnergy_J: actual_J,
                             modelEnergy_J: model_J,
                             attributedEnergy_J: attributed_J,
                             ratio: actual_J > 0 ? model_J / actual_J : .nan,
                             ledgerViolations: ledgerViolations,
                             maxLedgerError_W: maxLedgerError_W,
                             negativeResiduals: negativeResiduals,
                             samples: b - a + 1,
                             actualDelta_mAh: delta_mAh)
    }

    // ── Synthetic self-test ─────────────────────────────────────────────────

    /// Proves the harness's own arithmetic before it is allowed to judge anything:
    ///   1. constant power for a known duration against a known capacity delta
    ///      must yield ratio == 1.0 to floating-point exactness;
    ///   2. a deliberately broken ledger must be DETECTED (the check is not a
    ///      tautology inside the harness);
    ///   3. an AC sample mid-run must abort and refuse to produce a ratio;
    ///   4. a short run must refuse to produce a premature verdict.
    public static func selfTest() -> (passed: Bool, report: String) {
        var lines: [String] = ["SYNTHETIC SELF-TEST"]
        var ok = true
        func check(_ name: String, _ cond: Bool, _ detail: String) {
            ok = ok && cond
            lines.append("  [\(cond ? "PASS" : "FAIL")] \(name): \(detail)")
        }

        let scale = BatteryScale(fullChargeCapacity_mAh: 6197,
                                 designCapacity_mAh: 6249,
                                 nominalVoltage_V: 11.58,
                                 isCalibrated: false)
        let base = Date(timeIntervalSinceReferenceDate: 0)

        // 1 ── exact-arithmetic run: 100 mAh over an aligned 600 s at the exactly
        //      matching constant power. E_actual = 0.1 Ah * 11.58 V * 3600 = 4168.8 J.
        let expected_J = 100.0 / 1000 * scale.nominalVoltage_V * 3600
        let power_W = expected_J / 600.0
        let v1 = ModelValidator(scale: scale)
        var mAh = 3100.0
        var t = 0.0
        while t <= 660.0 {
            // Gauge steps 10 mAh at t = 60, 120, …, 660 — a 60 s publish cadence.
            if t >= 60, t.truncatingRemainder(dividingBy: 60) == 0 { mAh -= 10 }
            v1.record(synthetic(scale: scale, smoothed: power_W, attributed: power_W * 0.3,
                                gpu: power_W * 0.1, mAh: mAh, onAC: false),
                      at: base.addingTimeInterval(t))
            t += 5
        }
        if let run = v1.result(minimumSeconds: 600) {
            check("exact ratio", abs(run.ratio - 1.0) < 1e-9,
                  String(format: "ratio = %.12f for %.1f J vs %.1f J over %.0f s",
                         run.ratio, run.modelEnergy_J, run.actualEnergy_J,
                         run.ended.timeIntervalSince(run.started)))
            check("clean ledger", run.ledgerViolations == 0 && run.negativeResiduals == 0,
                  "\(run.ledgerViolations) violations, \(run.negativeResiduals) negative residuals")
        } else {
            check("exact ratio", false, "result() was nil for a complete 600 s synthetic window")
        }

        // 2 ── broken ledger must be detected: attributed + gpu exceed smoothed, so
        //      the clamped residual publishes 0 and the rows over-sum by 1 W.
        let v2 = ModelValidator(scale: scale)
        v2.record(synthetic(scale: scale, smoothed: 6.0, attributed: 5.0, gpu: 2.0,
                            mAh: 3000, onAC: false), at: base)
        // compute() needs gauge movement; ledger counters do not — read them via a run.
        v2.record(synthetic(scale: scale, smoothed: 6.0, attributed: 2.0, gpu: 1.0,
                            mAh: 2990, onAC: false), at: base.addingTimeInterval(60))
        v2.record(synthetic(scale: scale, smoothed: 6.0, attributed: 2.0, gpu: 1.0,
                            mAh: 2980, onAC: false), at: base.addingTimeInterval(120))
        if let run = v2.result(minimumSeconds: 0) {
            check("broken ledger detected",
                  run.ledgerViolations == 1 && run.negativeResiduals == 1
                      && abs(run.maxLedgerError_W - 1.0) < 1e-9,
                  String(format: "%d violation(s), max error %.3f W, %d negative residual(s)",
                         run.ledgerViolations, run.maxLedgerError_W, run.negativeResiduals))
        } else {
            check("broken ledger detected", false, "could not produce a run to inspect")
        }

        // 3 ── AC mid-run must abort: no ratio, and the reason is recorded.
        let v3 = ModelValidator(scale: scale)
        mAh = 3100; t = 0
        while t <= 300 {
            if t >= 60, t.truncatingRemainder(dividingBy: 60) == 0 { mAh -= 10 }
            v3.record(synthetic(scale: scale, smoothed: 5, attributed: 2, gpu: 0,
                                mAh: mAh, onAC: false), at: base.addingTimeInterval(t))
            t += 5
        }
        v3.record(synthetic(scale: scale, smoothed: 5, attributed: 2, gpu: 0,
                            mAh: mAh, onAC: true), at: base.addingTimeInterval(t))
        check("AC aborts the run",
              v3.result(minimumSeconds: 0) == nil && (v3.lastAbortReason?.contains("AC") ?? false),
              "result = nil, reason = \(v3.lastAbortReason ?? "<none>")")

        // 4 ── premature success must be refused: 120 s of data, 900 s required.
        let v4 = ModelValidator(scale: scale)
        mAh = 3100; t = 0
        while t <= 120 {
            if t >= 60, t.truncatingRemainder(dividingBy: 60) == 0 { mAh -= 10 }
            v4.record(synthetic(scale: scale, smoothed: 5, attributed: 2, gpu: 0,
                                mAh: mAh, onAC: false), at: base.addingTimeInterval(t))
            t += 5
        }
        check("no premature verdict", v4.result(minimumSeconds: 900) == nil,
              "result(minimumSeconds: 900) = nil after 120 s; status: \(v4.status)")

        return (ok, lines.joined(separator: "\n"))
    }

    /// Builds a minimal in-module Snapshot for the self-test. `residual_W` uses the
    /// same `max(0, …)` the real Monitor uses, so the self-test exercises exactly
    /// the published-ledger shape the harness will see in production.
    private static func synthetic(scale: BatteryScale, smoothed: Double,
                                  attributed: Double, gpu: Double,
                                  mAh: Double, onAC: Bool) -> PowerMonitor.Snapshot {
        let state = Battery.State(percent: 50, isCharging: false, onAC: onAC,
                                  cycleCount: 100, voltage_mV: 11580,
                                  amperage_mA: -500, remainingCapacity_mAh: mAh,
                                  timeRemaining_min: nil)
        return PowerMonitor.Snapshot(drains: [], apps: [],
                                     attributed_W: attributed, rails: [],
                                     gpu_W: gpu > 0 ? gpu : nil,
                                     fast_W: attributed + gpu,
                                     measured_W: nil, measuredAge: nil,
                                     smoothed_W: smoothed, isCalibrated: true,
                                     smcTotal_W: nil, smcGain: nil, baseline_W: nil,
                                     didJump: false,
                                     residual_W: max(0, smoothed - attributed - gpu),
                                     rawResidual_W: smoothed - attributed - gpu,
                                     scale: scale, state: state,
                                     coverage: 1, denied: 0, readable: 0,
                                     attempted: 0, interval: 5)
    }
}
