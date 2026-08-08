import Foundation
import CoreGraphics

/// Which Mac this is.
///
/// Several quantities in PowerKit are calibrated against one machine — the
/// backlight curve, the SMC rail key sets, the CPU-rail-to-battery factor — and
/// each needs to know whether it is running on the machine it was fitted for.
/// The SMC-derived ones are self-checking, because a key that does not exist
/// reads nil and produces no segment. A fitted curve has no such safeguard: it
/// returns a plausible number on any hardware. This is how it finds out.
public enum Hardware {

    /// `hw.model`, e.g. `Mac17,9`. Read once — it cannot change while running,
    /// and this is consulted on the tick path.
    public static let model: String = {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buf, &size, nil, 0) == 0 else { return "" }
        return String(cString: buf)
    }()
}

/// Estimates display backlight power from screen brightness.
///
/// This is the one part of the platform bucket that can be split off honestly,
/// and it is worth stating exactly why the others cannot. The SMC rails on this
/// hardware divide the machine by POWER-DELIVERY PHASE, not by subsystem —
/// measured, PZC0+PZC1 and PHPC+PHPS each sum to PSTR — so no amount of rail
/// arithmetic separates Wi-Fi from DRAM. The display is different only because
/// its power can be MODULATED and the response measured.
///
/// The curve below came from a brightness sweep on this machine with the CPU and
/// GPU rails measured and subtracted at each level, because changing brightness
/// wakes WindowServer and an earlier two-point run counted +2.1 W of CPU as
/// display power:
///
///     brightness    rest-of-machine
///        2%             3.96 W
///       25%             4.10 W
///       50%             7.40 W
///      100%            12.41 W
///
/// Monotonic, span ~8.45 W. The 3.96 W at minimum is the floor that is NOT the
/// display — DRAM, SSD, radios, always-on domains — so display power is the
/// EXCESS over that floor, which is why the model reports ~0 W at minimum
/// brightness rather than ~4 W.
///
/// PROVENANCE: this is modeled, never measured live. It is a calibrated response
/// curve for one panel, and it is labelled as an estimate everywhere it surfaces.
/// A second machine will have a different panel and a different span, which is
/// why the coefficients are one struct rather than sprinkled through the code.
public struct DisplayPowerModel: Equatable {

    /// Watts above the platform floor at full brightness.
    public let spanWatts: Double
    /// Brightness below which the backlight contributes nothing measurable.
    public let deadZone: Double
    /// Curve shape. Backlight power against the OS brightness slider is not
    /// linear: measured, it is flat to ~20% and then climbs steeply, so a
    /// straight line badly over-reports at the low settings people actually use.
    /// An exponent above 1 reproduces that shape above the dead zone.
    public let exponent: Double

    /// Re-derived after the original sweep was found to have subtracted CPU at
    /// 1.0x PPMC, when a watt of PPMC actually costs ~1.27 W at the battery — so
    /// it credited CPU power to the display.
    ///
    ///     span      8.45 -> 8.19 W    (small)
    ///     deadZone  0.02 -> 0.20      (large, and the one that mattered)
    ///     exponent  1.8  -> 1.75
    ///
    /// The dead zone is the real correction. Below ~20% the backlight draws
    /// nothing measurable, and the old 0.02 had the model claiming watts across
    /// that whole range: at 37.5% brightness it asserted 1.36 W where the
    /// measurement says 0.56 W. Fitted R2 = 0.995 over 9 levels, monotone in
    /// brightness, and stable across CPU coefficients 1.00-1.33 (span moves only
    /// 8.12 -> 8.20), so the fit does not hinge on getting that coefficient exact.
    public static let measuredOnThisMac = DisplayPowerModel(
        spanWatts: 8.19, deadZone: 0.20, exponent: 1.75)

    /// The machine the sweep above was actually run on. A curve fitted to one
    /// panel is a statement about that panel and nothing else.
    public static let calibratedModel = "Mac17,9"

    /// The model to use here, or nil on hardware it was never fitted for.
    ///
    /// The gate matters more than it looks, because the display claim is not
    /// merely displayed — it is SUBTRACTED from the platform bucket before the
    /// remainder is reported as unattributed. So on a different panel the curve
    /// does not just print a wrong display number; it silently moves watts out
    /// of the one bucket in this app whose entire job is to be honest about what
    /// is unaccounted for. A machine with a dimmer panel would have watts
    /// invented and taken from the residual; a brighter one would have them left
    /// there under the wrong name.
    ///
    /// Returning nil produces no display segment at all, which is the correct
    /// output for a quantity nobody has measured on this hardware. The rail
    /// (`DisplayRail`) is unaffected and remains preferred wherever it reads —
    /// it is a sensor, not a fit, so it needs no such gate.
    public static var forThisMachine: DisplayPowerModel? {
        Hardware.model == calibratedModel ? measuredOnThisMac : nil
    }

    public init(spanWatts: Double, deadZone: Double, exponent: Double) {
        self.spanWatts = spanWatts
        self.deadZone = deadZone
        self.exponent = exponent
    }

    /// Estimated backlight watts for a 0...1 brightness.
    public func watts(brightness: Double) -> Double {
        guard brightness.isFinite else { return 0 }
        let b = min(max(brightness, 0), 1)
        guard b > deadZone else { return 0 }
        let t = (b - deadZone) / (1 - deadZone)
        return spanWatts * pow(t, exponent)
    }
}

/// The display's own power rail — a MEASUREMENT, not a model.
///
/// `PDBR` tracked the brightness sweep from 0.204 W to 8.197 W, a 40x swing,
/// and its full-scale value matches the independently fitted span (8.19 W) to
/// within noise. That is the signature of the backlight rail itself.
///
/// It is preferred over the brightness curve wherever it is readable, for a
/// reason that first looked like a disqualification: PDBR varies at FIXED
/// brightness (0.388, 0.475, 0.492 W all at 0.375). An earlier investigation
/// rejected it for that. But this is a mini-LED panel with local dimming, so
/// backlight power genuinely depends on what is ON the screen, not only on the
/// slider — which means the rail captures something no brightness curve can,
/// and the variation is signal rather than noise.
///
/// The model remains the fallback for machines whose display rail cannot be
/// read, and it is still labelled modeled there.
public enum DisplayRail {
    public static let key = "PDBR"

    /// Watts, or nil when the rail is absent or implausible. A display cannot
    /// draw more than this panel's measured full-scale draw plus margin, and a
    /// reading above that is a misidentified key on different hardware.
    public static func watts(_ smc: SMC?) -> Double? {
        guard let v = smc?.read(key)?.value, v.isFinite, v >= 0, v <= 15 else { return nil }
        return v
    }
}

/// Reads the current brightness of the main display.
///
/// DisplayServices is private, so it is dlopen'd rather than linked, and every
/// failure path returns nil rather than a fabricated value — a display whose
/// brightness cannot be read must produce NO display segment, not a zero one.
public enum DisplayBrightness {

    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32

    private static let getFn: GetFn? = {
        guard let h = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_LAZY), let sym = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(sym, to: GetFn.self)
    }()

    public static var isAvailable: Bool { getFn != nil }

    /// 0...1, or nil if unreadable — an external display, a closed lid, or a
    /// macOS release that moved the symbol.
    public static func current() -> Double? {
        guard let f = getFn else { return nil }
        var v: Float = 0
        guard f(CGMainDisplayID(), &v) == 0, v.isFinite, v >= 0, v <= 1 else { return nil }
        return Double(v)
    }
}


// ─────────────────────────────────────────────────────────────────────────────

/// Subsystem rails identified by driving one subsystem at a time and measuring
/// which rails respond, with the known confounders subtracted at each level.
///
/// This is the same discriminator that established the CPU rail (PPMC: +13.3 W
/// under an all-core load, +1.5 W under a GPU load) and the GPU rail. Both
/// entries below were found the same way and both carry a NEGATIVE control,
/// which is what separates them from a coincidence.
public enum SubsystemRails {

    /// Were these rails identified on the machine now running?
    ///
    /// Everything in this enum came from load experiments on one Mac: drive one
    /// subsystem, watch which rails move, confirm with a negative control. That
    /// is a strong method and it produces a result about ONE SoC's power tree.
    ///
    /// SMC keys are not a namespace anyone standardised. `P3F2` existing on
    /// another Mac is not evidence it means memory there, and a key that exists
    /// but means something else passes every plausibility check in `watts` —
    /// finite, non-negative, under the cap — while putting watts under a
    /// confidently wrong name. The failure is invisible, which is what makes it
    /// worth gating rather than risking.
    ///
    /// Off this machine the subsystem segments are simply not produced, and that
    /// power stays in the unattributed bucket where it is honestly labelled. A
    /// smaller ledger that is true beats a fuller one that is decorated.
    public static var isCalibratedHardware: Bool {
        Hardware.model == DisplayPowerModel.calibratedModel
    }

    /// `P3F2 + PZD1`. Memory — DRAM, its controller, or the fabric serving them.
    ///
    /// Found by a CPU-MATCHED contrast rather than idle-vs-load: ten threads of
    /// register-resident FP spin (no DRAM traffic) against ten threads streaming
    /// 249 GB/s. Same cores saturated, so the only difference is memory traffic.
    /// 19.6 W of CPU package power moves P3F2 by 0.12 W; DRAM traffic moves it by
    /// 7.50 W — a 21x discriminator, and 112x for PZD1.
    ///
    /// The pair calibrates to ~1.0 W per watt of measured residual, which is why
    /// it is used at face value. Six further rails show the same signature but
    /// double-count this pair, so they are diagnostics, not addends.
    public static var memoryKeys: [String] { isCalibratedHardware ? ["P3F2", "PZD1"] : [] }

    /// `PN00`. Storage — the SSD path.
    ///
    /// +4.5 W under real flash I/O while reading 0.51 W under 34 W of CPU and
    /// 249 GB/s of DRAM traffic. The negative control is what makes it: a
    /// workload of the same SHAPE that never reaches flash — 1.03M IOPS/s served
    /// entirely from the buffer cache — did not move it at all, while the memory
    /// rails did. So it tracks actual flash traffic, not syscall volume.
    ///
    /// PH0R and PHCR discriminate even harder (~1000x, with a visible NVMe
    /// idle-timer decay after each burst) but sit at ~0.03 W at idle, so they
    /// name almost nothing of the idle bucket. PN00 carries a ~0.52 W idle floor
    /// that is either genuine controller idle draw or a sensor offset; it
    /// quantises and moves, which argues for a live reading.
    public static var storageKeys: [String] { isCalibratedHardware ? ["PN00"] : [] }

    /// A watt of PPMC costs this much at the battery.
    ///
    /// Measured across three load levels and pooled per-sample OLS (n=115,
    /// slope 1.270, intercept 2.98 W; per-level 1.17-1.33, rising with load).
    /// The ledger previously took PPMC at face value, so 17-25% of CPU power was
    /// being filed as unattributed — under a 20 W load, 4-6 W of it.
    ///
    /// HONEST AMBIGUITY: this cannot currently distinguish "PPMC excludes some
    /// CPU-adjacent domains" from "buck-converter loss on the battery-to-die path
    /// that belongs to everything". If it is the latter the right name is
    /// conversion loss, not CPU. The memory pair calibrating at ~1.0 rather than
    /// ~1.27 argues mildly for the former. Revisit if a rail-derived quantity on
    /// AC shows the same factor.
    ///
    /// 1.0 off this machine — which is NOT a claim that the factor is 1.0 there,
    /// it is the absence of a correction. Applying 1.27 to a different SoC's
    /// package rail would inflate the CPU claim by 27% on no evidence, and since
    /// the claim is subtracted from the platform bucket in the waterfall, the
    /// error lands squarely in the unattributed figure this app exists to report
    /// honestly. Under-claiming leaves watts in that bucket, correctly labelled
    /// as not-yet-explained; over-claiming invents an explanation.
    public static var cpuRailToBattery: Double { isCalibratedHardware ? 1.27 : 1.0 }

    /// Sum of a rail set, or nil if none of them read — absent rails must produce
    /// NO segment, never a zero one, because these keys are calibrated on one
    /// machine and a different Mac may not have them.
    public static func watts(_ smc: SMC?, keys: [String], max cap: Double = 60) -> Double? {
        guard let smc else { return nil }
        var total = 0.0
        var any = false
        for k in keys {
            guard let v = smc.read(k)?.value, v.isFinite, v >= 0, v <= cap else { continue }
            total += v
            any = true
        }
        return any ? total : nil
    }
}
