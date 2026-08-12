import Foundation
import CoreGraphics
import IOKit
import IOKit.pwr_mgt
import PowerKit

/// Calibrates the display backlight power curve by modulating screen brightness
/// and measuring what the machine's total draw does in response.
///
/// This is the same discriminator method that identified the CPU rail (PPMC) and
/// the GPU rail: drive one subsystem, hold the rest still, and keep the rails
/// whose response is large relative to their idle value. Guessing a rail from its
/// four-character key is not a substitute — `PDBR` looks like it should mean
/// "display" and does not behave like it.
///
/// THREE THINGS THE 2026-08 RERUN CHANGED, each because the first sweep was wrong
/// about them:
///
/// 1. CPU IS SUBTRACTED AT 1.27x PPMC, NOT 1.0x. Changing brightness wakes
///    WindowServer, so PPMC moves alongside the display and must be removed. The
///    first sweep removed it at face value. A later regression of battery power
///    against PPMC (n=115) found a slope of 1.27 W per PPMC watt with a 1.17-1.33
///    range: PPMC UNDERCOUNTS what the CPU costs the battery, so subtracting it
///    1:1 leaves CPU power sitting in the display's column. The sweep now reports
///    the fit at every coefficient in that range so the reader can see how much
///    of the answer rests on it.
///
/// 2. NINE LEVELS, VISITED OUT OF ORDER. A monotone ramp cannot tell a brightness
///    response from anything else that drifts during the run — thermals, a
///    background download, this process's own warmup. The levels are visited in a
///    zigzag so brightness is nearly uncorrelated with time (r = 0.16), and the
///    time index is carried through to the fit as a check.
///
/// 3. BOTH BRIGHTNESS SOURCES ARE READ AT EVERY LEVEL. DisplayServices and the
///    IORegistry disagree — 0.375 against 0.500 at the same instant — and the
///    model is only as good as the axis it is plotted against. Setting known
///    values and reading both back is the one experiment that settles which
///    number tracks the panel.
///
/// Brightness is restored on every exit path, including a signal, because leaving
/// someone's screen at 2% is a worse outcome than learning nothing.
enum DisplayExperiment {

    // DisplayServices is private, so it is dlopen'd rather than linked. The public
    // IODisplaySetFloatParameter path does not work on Apple Silicon internal
    // panels — it returns success and changes nothing.
    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32

    private static var handle: UnsafeMutableRawPointer?
    private static var getFn: GetFn?
    private static var setFn: SetFn?
    private static var displayID: UInt32 = 0
    private static var original: Float = -1
    private static var sleepAssertion: IOPMAssertionID = 0

    private static func load() -> Bool {
        handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
                        RTLD_LAZY)
        guard let h = handle else { return false }
        guard let g = dlsym(h, "DisplayServicesGetBrightness"),
              let s = dlsym(h, "DisplayServicesSetBrightness") else { return false }
        getFn = unsafeBitCast(g, to: GetFn.self)
        setFn = unsafeBitCast(s, to: SetFn.self)
        displayID = CGMainDisplayID()
        return true
    }

    private static func brightness() -> Float? {
        var v: Float = 0
        guard let f = getFn, f(displayID, &v) == 0 else { return nil }
        return v
    }

    @discardableResult
    private static func setBrightness(_ v: Float) -> Bool {
        guard let f = setFn else { return false }
        return f(displayID, max(0.02, min(1.0, v))) == 0
    }

    private static func restore() {
        if original >= 0 { setBrightness(original) }
    }

    // ── The other brightness source ─────────────────────────────────────────
    // AppleARMBacklight is the panel's own driver. Its IODisplayParameters carry
    // four independent numbers, and they are not the same number in four scales:
    //   brightness      0...65536, the value DisplayServices is supposed to mirror
    //   rawBrightness   0...2047,  the driver-side code actually programmed
    //   BrightnessMilliNits        target luminance, calibrated per panel
    //   BrightnessMicroAmps        LED string current — the closest thing the
    //                              machine has to a direct backlight power reading
    private struct PanelState {
        var brightness: Double?     // 0...1
        var raw: Double?            // 0...1
        var nits: Double?
        var microAmps: Double?
    }

    private static func panelState() -> PanelState {
        var st = PanelState()
        let svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                              IOServiceMatching("AppleARMBacklight"))
        guard svc != 0 else { return st }
        defer { IOObjectRelease(svc) }
        guard let raw = IORegistryEntryCreateCFProperty(
            svc, "IODisplayParameters" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any] else { return st }

        func field(_ name: String, _ key: String) -> Double? {
            guard let d = raw[name] as? [String: Any],
                  let v = (d[key] as? NSNumber)?.doubleValue else { return nil }
            return v
        }
        func normalized(_ name: String) -> Double? {
            guard let v = field(name, "value"), let mx = field(name, "max"), mx > 0 else { return nil }
            let mn = field(name, "min") ?? 0
            return (v - mn) / (mx - mn)
        }
        st.brightness = normalized("brightness")
        st.raw = normalized("rawBrightness")
        st.nits = field("BrightnessMilliNits", "value").map { $0 / 1000 }
        st.microAmps = field("BrightnessMicroAmps", "value")
        return st
    }

    // ── Rails ───────────────────────────────────────────────────────────────
    // Read by key, not by scan(). A full scan() walks every SMC key by index —
    // hundreds of IOKit round trips — and at 2 Hz that puts the tool's own CPU
    // cost into the very rail it is trying to subtract.
    //
    // PSTR is the total and PPMC the CPU. The rest are here because a rail that
    // moves with brightness is a candidate for carrying the backlight, and the
    // memory/storage rails (P3F2, PZD1, PN00, PH0R, PHCR) are here because they
    // are the ones most likely to be MISTAKEN for it.
    private static let railKeys = [
        "PSTR", "PPMC", "PR1b", "PR0b",
        "P3F2", "PZD1", "PN00", "PH0R", "PHCR", "PDBR",
        "PPBR", "PPSM", "P5SR", "PHPC", "PHPS",
    ]

    private struct Stat {
        var mean = 0.0
        var sd = 0.0
        var n = 0
    }

    private static func stat(_ xs: [Double]) -> Stat {
        guard !xs.isEmpty else { return Stat() }
        let m = xs.reduce(0, +) / Double(xs.count)
        let v = xs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(xs.count)
        return Stat(mean: m, sd: v.squareRoot(), n: xs.count)
    }

    private static func sampleRails(_ smc: SMC, seconds: Double) -> [String: Stat] {
        var series: [String: [Double]] = [:]
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            for k in railKeys {
                guard let v = smc.read(k)?.value, v.isFinite else { continue }
                series[k, default: []].append(v)
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return series.mapValues(stat)
    }

    // ── One measured level ──────────────────────────────────────────────────
    private struct Level {
        let order: Int          // when in the run it was visited
        let requested: Double
        let ds: Double          // DisplayServicesGetBrightness readback
        let ioreg: Double       // IORegistry brightness readback
        let raw: Double
        let nits: Double
        let microAmps: Double
        let rails: [String: Stat]

        func mean(_ k: String) -> Double { rails[k]?.mean ?? 0 }
        var gpu: Double { mean("PR1b") + mean("PR0b") }
        /// Whole-machine draw with CPU removed at coefficient `k` and GPU removed
        /// at face value. This is the quantity the display curve is fitted to.
        func residual(cpuCoefficient k: Double) -> Double {
            mean("PSTR") - k * mean("PPMC") - gpu
        }
    }

    // ── Curve fitting ───────────────────────────────────────────────────────
    // spanWatts * ((b - deadZone) / (1 - deadZone)) ^ exponent, plus a free floor.
    // deadZone and exponent enter non-linearly, so they are gridded; span and floor
    // fall out of ordinary least squares at each grid point. n = 9, so a grid is
    // both adequate and more honest than an optimizer that would happily report six
    // significant figures from nine noisy points.
    private struct Fit {
        var span = 0.0
        var floor = 0.0
        var deadZone = 0.0
        var exponent = 1.0
        var rmse = Double.infinity
        var r2 = 0.0
    }

    private static func fit(_ xs: [Double], _ ys: [Double]) -> Fit {
        guard xs.count == ys.count, xs.count >= 3 else { return Fit() }
        let ybar = ys.reduce(0, +) / Double(ys.count)
        let sst = ys.map { ($0 - ybar) * ($0 - ybar) }.reduce(0, +)
        var best = Fit()
        var dz = 0.0
        while dz <= 0.30 {
            var ex = 0.6
            while ex <= 3.5 {
                // t is the shaped predictor; the model is linear in (floor, span).
                let ts = xs.map { x -> Double in
                    x <= dz ? 0 : pow((x - dz) / (1 - dz), ex)
                }
                let tbar = ts.reduce(0, +) / Double(ts.count)
                var sxy = 0.0, sxx = 0.0
                for i in 0..<ts.count {
                    sxy += (ts[i] - tbar) * (ys[i] - ybar)
                    sxx += (ts[i] - tbar) * (ts[i] - tbar)
                }
                if sxx > 1e-12 {
                    let span = sxy / sxx
                    let floor = ybar - span * tbar
                    var sse = 0.0
                    for i in 0..<ts.count {
                        let e = ys[i] - (floor + span * ts[i])
                        sse += e * e
                    }
                    let rmse = (sse / Double(ts.count)).squareRoot()
                    if rmse < best.rmse {
                        best = Fit(span: span, floor: floor, deadZone: dz, exponent: ex,
                                   rmse: rmse, r2: sst > 0 ? 1 - sse / sst : 0)
                    }
                }
                ex += 0.05
            }
            dz += 0.01
        }
        return best
    }

    /// Pearson r, used to say which brightness source is linear in what was set.
    private static func correlation(_ xs: [Double], _ ys: [Double]) -> Double {
        guard xs.count == ys.count, xs.count > 1 else { return .nan }
        let n = Double(xs.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in 0..<xs.count {
            sxy += (xs[i] - mx) * (ys[i] - my)
            sxx += (xs[i] - mx) * (xs[i] - mx)
            syy += (ys[i] - my) * (ys[i] - my)
        }
        return sxx > 0 && syy > 0 ? sxy / (sxx * syy).squareRoot() : .nan
    }

    /// Slope and intercept of y on x, so a claimed identity can be checked rather
    /// than eyeballed ("ioreg = 1.00 x set + 0.00" is a different claim from
    /// "ioreg correlates with set").
    private static func line(_ xs: [Double], _ ys: [Double]) -> (slope: Double, intercept: Double) {
        let n = Double(xs.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0
        for i in 0..<xs.count {
            sxy += (xs[i] - mx) * (ys[i] - my)
            sxx += (xs[i] - mx) * (xs[i] - mx)
        }
        guard sxx > 1e-12 else { return (.nan, .nan) }
        let s = sxy / sxx
        return (s, my - s * mx)
    }

    // ── The run ─────────────────────────────────────────────────────────────
    static func run(settle: Double = 6, dwell: Double = 15) {
        guard let smc = SMC() else { print("SMC unavailable"); exit(1) }
        guard load() else { print("DisplayServices unavailable."); exit(1) }
        guard let b0 = brightness() else { print("Cannot read brightness."); exit(1) }
        original = b0
        atexit { DisplayExperiment.restore() }
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig) { _ in DisplayExperiment.restore(); _exit(1) }
        }
        // Process-scoped assertion, released when this process dies. Not a settings
        // change: nothing in `pmset` moves. The screen saver at 300 s idle would
        // otherwise land inside a 190 s sweep that generates no user input, and it
        // would arrive as a brightness step this tool did not ask for.
        IOPMAssertionCreateWithName("PreventUserIdleDisplaySleep" as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "Anode display sweep" as CFString,
                                    &sleepAssertion)
        defer { if sleepAssertion != 0 { IOPMAssertionRelease(sleepAssertion) } }

        // Ascending levels, visited in a zigzag. See the type comment: the order
        // decorrelates brightness from elapsed time (r = 0.16) so drift during the
        // run cannot impersonate a backlight curve.
        let ladder: [Double] = [0.02, 0.125, 0.25, 0.375, 0.50, 0.625, 0.75, 0.875, 1.00]
        let visitOrder = [4, 0, 8, 2, 6, 1, 7, 3, 5]

        let p0 = panelState()
        print(String(format: "display sweep · %d levels · %.0fs each · ~%.0fs total",
                     ladder.count, settle + dwell,
                     Double(ladder.count) * (settle + dwell)))
        print(String(format: "starting brightness: DisplayServices %.4f · IORegistry %@ · %@ nits · %@ uA",
                     b0,
                     p0.brightness.map { String(format: "%.4f", $0) } ?? "—",
                     p0.nits.map { String(format: "%.0f", $0) } ?? "—",
                     p0.microAmps.map { String(format: "%.0f", $0) } ?? "—"))
        print("brightness is restored on every exit path, including ctrl-C\n")

        var levels: [Level] = []
        for (step, idx) in visitOrder.enumerated() {
            let want = ladder[idx]
            setBrightness(Float(want))
            Thread.sleep(forTimeInterval: settle)
            let ds = Double(brightness() ?? Float.nan)
            let ps = panelState()
            let rails = sampleRails(smc, seconds: dwell)
            let lv = Level(order: step, requested: want, ds: ds,
                           ioreg: ps.brightness ?? .nan, raw: ps.raw ?? .nan,
                           nits: ps.nits ?? .nan, microAmps: ps.microAmps ?? .nan,
                           rails: rails)
            levels.append(lv)
            print(String(format:
                "  set %.3f  ds %.3f  ioreg %.3f  raw %.3f  %6.1f nits %6.0f uA | PSTR %6.2f±%.2f  PPMC %5.2f±%.2f  GPU %4.2f",
                want, lv.ds, lv.ioreg, lv.raw, lv.nits, lv.microAmps,
                lv.mean("PSTR"), rails["PSTR"]?.sd ?? 0,
                lv.mean("PPMC"), rails["PPMC"]?.sd ?? 0, lv.gpu))
        }
        restore()
        levels.sort { $0.requested < $1.requested }

        // ── Machine-readable dump, so the fit can be redone without rerunning ──
        print("\nCSV")
        print("order,set,ds,ioreg,raw,nits,microamps," + railKeys.joined(separator: ","))
        for l in levels {
            var row = [String(format: "%d,%.4f,%.4f,%.4f,%.4f,%.2f,%.1f",
                              l.order, l.requested, l.ds, l.ioreg, l.raw, l.nits, l.microAmps)]
            row.append(contentsOf: railKeys.map { String(format: "%.4f", l.mean($0)) })
            print(row.joined(separator: ","))
        }

        // ── Which brightness source tracks the panel ────────────────────────
        let set = levels.map(\.requested)
        print("\nBRIGHTNESS SOURCES  (against the value actually set)")
        for (name, ys) in [("DisplayServices", levels.map(\.ds)),
                           ("IORegistry brightness", levels.map(\.ioreg)),
                           ("IORegistry rawBrightness", levels.map(\.raw)),
                           ("nits", levels.map(\.nits)),
                           ("microAmps", levels.map(\.microAmps))] {
            guard ys.allSatisfy({ $0.isFinite }) else { print("  \(name): unreadable"); continue }
            let l = line(set, ys)
            print(String(format: "  %-26@ r %+.4f   slope %8.3f  intercept %8.3f",
                         name as NSString, correlation(set, ys), l.slope, l.intercept))
        }

        // ── The rails, level by level ───────────────────────────────────────
        print("\nRAIL RESPONSE  (min-brightness value -> full-brightness value, delta)")
        for k in railKeys {
            let lo = levels.first?.mean(k) ?? 0, hi = levels.last?.mean(k) ?? 0
            print(String(format: "  %-5@ %7.3f -> %7.3f   %+7.3f W", k as NSString, lo, hi, hi - lo))
        }

        // ── Sensitivity to the CPU coefficient ──────────────────────────────
        print("\nRESIDUAL  PSTR - k·PPMC - GPU, at each CPU coefficient")
        let coefficients = [1.00, 1.17, 1.27, 1.33]
        var header = "  set   "
        for k in coefficients { header += String(format: "  k=%.2f", k) }
        print(header)
        for l in levels {
            var row = String(format: "  %.3f ", l.requested)
            for k in coefficients { row += String(format: "  %6.2f", l.residual(cpuCoefficient: k)) }
            print(row)
        }

        print("\nFIT  span·((b-dead)/(1-dead))^exp + floor, fitted against DisplayServices brightness")
        print("  k      span     floor    dead    exp    RMSE     R2")
        for k in coefficients {
            let ys = levels.map { $0.residual(cpuCoefficient: k) }
            let f = fit(levels.map(\.ds), ys)
            print(String(format: "  %.2f  %7.3f  %7.3f  %6.3f  %5.2f  %6.3f  %6.3f",
                         k, f.span, f.floor, f.deadZone, f.exponent, f.rmse, f.r2))
        }
        print("  same, fitted against IORegistry brightness")
        for k in coefficients {
            let ys = levels.map { $0.residual(cpuCoefficient: k) }
            let f = fit(levels.map(\.ioreg), ys)
            print(String(format: "  %.2f  %7.3f  %7.3f  %6.3f  %5.2f  %6.3f  %6.3f",
                         k, f.span, f.floor, f.deadZone, f.exponent, f.rmse, f.r2))
        }

        // ── Confounds worth printing rather than hoping about ───────────────
        let byTime = levels.sorted { $0.order < $1.order }
        print(String(format: "\nCONFOUND CHECKS"))
        print(String(format: "  brightness vs visit order      r %+.3f  (near 0 = drift cannot mimic the curve)",
                     correlation(byTime.map { Double($0.order) }, byTime.map(\.requested))))
        print(String(format: "  PPMC vs brightness             r %+.3f  (the WindowServer confound; it is subtracted, not assumed absent)",
                     correlation(set, levels.map { $0.mean("PPMC") })))
        print(String(format: "  PPMC drift across the run      %+.2f W first visit -> last visit",
                     (byTime.last?.mean("PPMC") ?? 0) - (byTime.first?.mean("PPMC") ?? 0)))
        let r127 = levels.map { $0.residual(cpuCoefficient: 1.27) }
        var monotone = true
        for i in 1..<r127.count where r127[i] < r127[i - 1] - 0.15 { monotone = false }
        print(monotone
              ? "  residual is MONOTONE in brightness — consistent with a real backlight curve"
              : "  residual is NOT monotone — it is not tracking brightness cleanly; treat as contaminated")

        print(String(format: "\nrestored brightness to %.3f (was %.3f)",
                     Double(brightness() ?? b0), Double(b0)))
    }
}
