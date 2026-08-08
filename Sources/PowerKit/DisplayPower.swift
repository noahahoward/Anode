import Foundation
import CoreGraphics

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
