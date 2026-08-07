import Foundation
import CoreGraphics
import PowerKit

/// Identifies which SMC rails carry the display backlight, by modulating screen
/// brightness and watching which rails move with it.
///
/// This is the same discriminator method that identified the CPU rail (PPMC) and
/// the GPU rail (PR1b): drive one subsystem, hold the rest still, and keep the
/// rails whose response is large relative to their idle value. Guessing a rail
/// from its four-character key is not a substitute — `PDBR` looks like it should
/// mean "display" and does not behave like it.
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

    /// Mean of every P* float rail over `seconds`, sampled at 2 Hz.
    private static func sampleRails(_ smc: SMC, seconds: Double) -> [String: Double] {
        var sums: [String: Double] = [:]
        var n = 0
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            for s in smc.scan()
            where s.key.hasPrefix("P") && s.type == "flt" && s.value.isFinite {
                sums[s.key, default: 0] += s.value
            }
            n += 1
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard n > 0 else { return [:] }
        return sums.mapValues { $0 / Double(n) }
    }

    static func run(settle: Double = 8, dwell: Double = 14) {
        guard let smc = SMC() else { print("SMC unavailable"); exit(1) }
        guard load() else { print("DisplayServices unavailable."); exit(1) }
        guard let b0 = brightness() else { print("Cannot read brightness."); exit(1) }
        original = b0
        atexit { DisplayExperiment.restore() }
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig) { _ in DisplayExperiment.restore(); _exit(1) }
        }

        // Several levels, not two. A single hi/lo pair cannot tell a real
        // backlight curve from a coincidence, and the previous run was ruined by
        // exactly that: changing brightness wakes WindowServer, so PPMC moved
        // +2.1 W alongside the display and got counted as display power.
        //
        // The fix is not to hold the CPU still — that is impossible — but to
        // MEASURE it and subtract it. PPMC and the GPU rail are known, so at each
        // level the display estimate is PSTR minus both.
        let levels: [Float] = [0.02, 0.25, 0.50, 0.75, 1.00]
        print(String(format: "display sweep · current brightness %.0f%% · %d levels, %.0fs each",
                     b0 * 100, levels.count, settle + dwell))
        print("brightness is restored on every exit path, including ctrl-C\n")

        var results: [(Float, Double, Double, Double, Double)] = []
        for lv in levels {
            setBrightness(lv)
            Thread.sleep(forTimeInterval: settle)
            let m = sampleRails(smc, seconds: dwell)
            let pstr = m["PSTR"] ?? 0
            let ppmc = m["PPMC"] ?? 0
            let gpu  = (m["PR1b"] ?? 0) + (m["PR0b"] ?? 0)
            let disp = max(0, pstr - ppmc - gpu)
            results.append((lv, pstr, ppmc, gpu, disp))
            print(String(format: "  %3.0f%%  PSTR %6.2f  PPMC %5.2f  GPU %5.2f  ->  rest %6.2f W",
                         lv * 100, pstr, ppmc, gpu, disp))
        }
        restore()

        guard let lo = results.first, let hi = results.last else { return }
        let span = hi.4 - lo.4
        print(String(format: "\nrest-of-machine at 2%%: %.2f W   at 100%%: %.2f W   span %+.2f W",
                     lo.4, hi.4, span))
        print(String(format: "CPU rail moved %+.2f W across the sweep (this is the confound, now subtracted)",
                     hi.2 - lo.2))

        // Monotonic in brightness is the actual test. A backlight must rise with
        // every step; a rail that wanders is responding to something else.
        var monotonic = true
        for i in 1..<results.count where results[i].4 < results[i-1].4 - 0.15 { monotonic = false }
        print(monotonic
              ? "\nMONOTONIC in brightness — consistent with a real backlight curve."
              : "\nNOT monotonic — the residual is not tracking brightness cleanly; treat as contaminated.")
        if span > 0.5 {
            print(String(format: "display at your usual %.0f%%: roughly %.2f W",
                         b0 * 100, lo.4 + Double(b0) * span))
        }
        print(String(format: "\nrestored brightness to %.0f%%", (brightness() ?? b0) * 100))
    }
}
