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
    /// linear — the sweep barely moved between 2% and 25%, then climbed steeply —
    /// so a straight line would badly over-report at the low settings people
    /// actually use. An exponent above 1 reproduces that shape.
    public let exponent: Double

    public static let measuredOnThisMac = DisplayPowerModel(
        spanWatts: 8.45, deadZone: 0.02, exponent: 1.8)

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
