import Foundation

/// Adaptive exponential smoothing with change-point detection.
///
/// The problem this solves: the raw menu bar figure was jumping 4.8 -> 10.08 -> 5.0
/// %/hr between reads. Most of that is not the machine changing — it is the battery
/// telemetry publishing a 60-second MEAN once a minute, so consecutive reads are
/// different windows, not different truths. A number that swings 2x is useless for
/// judging "how long will this last".
///
/// Naive heavy smoothing would fix the jitter and break the thing you actually want:
/// when you launch a game or close a browser, the reading must move NOW, not crawl
/// there over two minutes.
///
/// So: smooth hard by default, and jump when the change is real. "Real" means the
/// new reading sits outside a band around the current estimate for TWO consecutive
/// samples. One sample outside the band is treated as noise and largely ignored;
/// two in a row is a regime change and we snap to it. That gives a steady readout
/// that still reacts within ~2 ticks of a genuine load change.
public final class AdaptiveSmoother {

    /// Weight given to each new sample in steady state. Lower = steadier.
    private let alpha: Double
    /// Weight applied once a regime change is confirmed. Near 1 = snap.
    private let snapAlpha: Double
    /// A sample must deviate by more than max(relBand * estimate, absBand) to count
    /// as an outlier. The absolute floor stops tiny values from flapping.
    private let relBand: Double
    private let absBand: Double
    /// Consecutive outliers required before snapping.
    private let confirmations: Int

    private var estimate: Double?
    private var pending: [Double] = []

    public init(alpha: Double = 0.25,
                snapAlpha: Double = 0.8,
                relBand: Double = 0.35,
                absBand: Double = 0.4,
                confirmations: Int = 2) {
        self.alpha = alpha
        self.snapAlpha = snapAlpha
        self.relBand = relBand
        self.absBand = absBand
        self.confirmations = confirmations
    }

    public var value: Double? { estimate }

    /// True when the last update was a confirmed regime change rather than drift.
    public private(set) var didJump = false

    @discardableResult
    public func update(_ x: Double) -> Double {
        didJump = false

        guard let e = estimate else {
            estimate = x
            return x
        }

        let band = max(relBand * abs(e), absBand)

        if abs(x - e) > band {
            // Outside the band. Could be a spike, could be a real change — wait and see.
            pending.append(x)
            if pending.count >= confirmations {
                // Confirmed. Snap toward the mean of the confirming samples, not the
                // last one, so a single extreme value doesn't set the new level.
                let target = pending.reduce(0, +) / Double(pending.count)
                estimate = e + snapAlpha * (target - e)
                pending.removeAll()
                didJump = true
            } else {
                // Unconfirmed outlier: let it nudge the estimate only slightly, so a
                // genuine ramp still moves us even before confirmation.
                estimate = e + (alpha * 0.25) * (x - e)
            }
        } else {
            // Inside the band: ordinary smoothing, and the outlier streak is broken.
            pending.removeAll()
            estimate = e + alpha * (x - e)
        }

        return estimate!
    }

    public func reset() {
        estimate = nil
        pending.removeAll()
        didJump = false
    }
}

/// Learns the machine's unattributable BASELINE power, so a fast partial signal can
/// be reported at the slow gauge's accuracy.
///
/// The battery gas gauge is accurate but publishes a 60 s mean once a minute.
/// Per-process CPU joules plus the GPU rail update every tick but cover only part of
/// the machine — measured here, about 27% of total draw.
///
/// The fusion must be ADDITIVE, not multiplicative. A multiplicative model
/// (`total = k * fast`) says every watt of display, Wi-Fi, SSD and kernel power
/// scales with CPU activity, which is false — those are roughly constant while the
/// screen is on. Measured consequence of getting this wrong: with k ≈ 3.6, ordinary
/// CPU jitter of ±3 W became ±11 W of output swing and the display flapped between
/// 29 and 60 W. The additive model passes that same jitter through at 1:1.
///
///     baseline = gauge - fast        (display, radios, SSD, kernel — slow-moving)
///     estimate = baseline + fast     (fast responds instantly to app activity)
public final class BaselineCalibrator {
    private var baselineW: Double?
    private let alpha: Double

    public init(alpha: Double = 0.35) { self.alpha = alpha }

    /// Watts that belong to no process we can see. Nil until first calibration.
    public var baseline: Double? { baselineW }
    public var isCalibrated: Bool { baselineW != nil }

    /// Call whenever a fresh gauge measurement lands, with the fast signal averaged
    /// over the same period so like is compared with like.
    public func observe(fast: Double, slow: Double) {
        guard slow > 0.01 else { return }
        // Clamp at zero: if the fast signal ever exceeds the gauge (double-counted
        // rail, or a gauge window that missed a burst) the baseline is not negative,
        // it is unknown-but-small.
        let b = max(0, slow - fast)
        baselineW = baselineW.map { $0 + alpha * (b - $0) } ?? b
    }

    /// nil until at least one gauge measurement has been observed.
    public func estimate(fast: Double) -> Double? {
        baselineW.map { $0 + fast }
    }
}

/// Corrects a fast WHOLE-SYSTEM measurement against the authoritative gas gauge.
///
/// Distinct from `BaselineCalibrator`, and the distinction matters. That one fuses a
/// PARTIAL signal (CPU+GPU) and must be additive, because the part it cannot see is
/// roughly constant. This one corrects a signal that already measures the whole
/// machine — SMC `PSTR` — where the error is a systematic gain, not a missing term.
/// Measured on this hardware: PSTR reads 5.280 W against a gauge mean of 4.681 W
/// over the same 60 s window, a stable ratio of 1.128.
///
/// Multiplying a whole-system measurement by ~0.89 is safe; it does not amplify
/// partial-signal noise the way scaling CPU-only draw by 3.6 did.
public final class GainCalibrator {
    private var gain: Double?
    private let alpha: Double
    private let range: ClosedRange<Double>

    public init(alpha: Double = 0.3, range: ClosedRange<Double> = 0.5...2.0) {
        self.alpha = alpha
        self.range = range
    }

    public var value: Double? { gain }
    public var isCalibrated: Bool { gain != nil }

    public func observe(fast: Double, slow: Double) {
        guard fast > 0.05, slow > 0.05 else { return }
        let g = min(max(slow / fast, range.lowerBound), range.upperBound)
        gain = gain.map { $0 + alpha * (g - $0) } ?? g
    }

    /// Applies the correction. Before the first gauge window lands the gain is 1.0,
    /// so the raw measurement is used rather than nothing — PSTR is already close.
    public func corrected(_ fast: Double) -> Double { (gain ?? 1.0) * fast }
}
