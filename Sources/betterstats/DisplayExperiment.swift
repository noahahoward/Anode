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

    static func run(settle: Double = 6, dwell: Double = 12) {
        guard let smc = SMC() else { print("SMC unavailable"); exit(1) }
        guard load() else {
            print("DisplayServices unavailable — cannot modulate brightness on this system.")
            exit(1)
        }
        guard let b0 = brightness() else {
            print("Could not read current brightness; refusing to change it blind.")
            exit(1)
        }
        original = b0
        atexit { DisplayExperiment.restore() }
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig) { _ in DisplayExperiment.restore(); _exit(1) }
        }

        print(String(format: "display experiment · current brightness %.0f%%", b0 * 100))
        print("  settle \(Int(settle))s, dwell \(Int(dwell))s per level, brightness restored on exit\n")

        // Bright first, then dim: the panel's own thermal state drifts slowly, and
        // going high→low means any residual warmth inflates the DIM reading, which
        // makes the measured delta conservative rather than flattering.
        setBrightness(1.0); Thread.sleep(forTimeInterval: settle)
        let hi = sampleRails(smc, seconds: dwell)
        setBrightness(0.02); Thread.sleep(forTimeInterval: settle)
        let lo = sampleRails(smc, seconds: dwell)
        restore()

        let keys = Set(hi.keys).intersection(lo.keys).sorted()
        var rows: [(String, Double, Double, Double)] = []
        for k in keys {
            let h = hi[k] ?? 0, l = lo[k] ?? 0
            rows.append((k, l, h, h - l))
        }
        print(String(format: "%-6@ %10@ %10@ %10@  %@",
                     "rail" as NSString, "dim W" as NSString, "bright W" as NSString,
                     "delta W" as NSString, "verdict" as NSString))
        for r in rows.sorted(by: { abs($0.3) > abs($1.3) }) where abs(r.3) > 0.01 || r.2 > 0.05 {
            // A display rail must move a lot in absolute terms AND be dominated by
            // that movement — a big rail that wobbles 3% is just noise on a big rail.
            let share = r.2 > 0.001 ? r.3 / r.2 : 0
            let verdict = (r.3 > 0.15 && share > 0.35) ? "◄ DISPLAY"
                        : (abs(r.3) > 0.15 ? "  (moves)" : "")
            print(String(format: "%-6@ %10.4f %10.4f %+10.4f  %@",
                         r.0 as NSString, r.1, r.2, r.3, verdict as NSString))
        }
        print(String(format: "\nrestored brightness to %.0f%%", (brightness() ?? b0) * 100))
    }
}
