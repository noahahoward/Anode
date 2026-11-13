import Foundation

// How fast a charger charges this Mac, learned, so that Ready By knows how long the climb to the limit takes.
//
// Nothing here is shown to the person, and nothing here decides: `ChargePolicy` takes the number as an input.

/// The charge rate of each class of charger, in percent per minute, and what is known of it so far.
///
/// Chargers are told apart by their rated power in three bands: under 30 W, 30 to 65 W and over 65 W. A band that
/// nothing has been learned for has a slow guess (`defaultRate`), so an unknown charger starts the charge early and
/// not late. What is learned is a running average of measurements (`record`), kept inside
/// `ChargePolicy.chargeRateRange`.
public struct ChargeRate: Equatable, Codable {

    public enum Band: String, Codable, CaseIterable {
        /// Under 30 W: a phone-sized charger.
        case under30
        /// 30 W up to and including 65 W.
        case from30to65
        /// Over 65 W.
        case over65
    }

    /// The class a charger of `watts` rated power is in. A charger that says nothing (nil, or not a positive number)
    /// is taken for the slowest class.
    public static func band(forAdapterWatts watts: Double?) -> Band {
        guard let w = watts, w.isFinite, w > 0 else { return .under30 }
        if w < 30 { return .under30 }
        if w <= 65 { return .from30to65 }
        return .over65
    }

    /// What a band charges at until something has been measured for it, in percent per minute. Slow guesses: measured
    /// once, about 1.3 on a 100 W charger at 54 to 60%.
    public static func defaultRate(for band: Band) -> Double {
        switch band {
        case .under30: return 0.3
        case .from30to65: return 0.8
        case .over65: return 1.0
        }
    }

    /// Learned only between these charges, where charging is steady: below it a battery may be trickling, and above
    /// it the charge tapers (the policy counts that on its own).
    public static let measuredPercent = 20...80
    /// A measurement spans at least this long, so a handful of whole percents is enough to say a rate.
    public static let minimumSpan: TimeInterval = 5 * 60
    /// The average weighs the last this many measurements: a charger, a cable or a battery that changes is followed.
    public static let averagedOver = 20

    public struct Learned: Equatable, Codable {
        /// Percent per minute.
        public var rate: Double
        /// How many measurements it averages, at most `averagedOver`.
        public var samples: Int
    }

    /// By `Band.rawValue`: a dictionary keyed by an enum is stored as a flat array, and this is read by eye as often as
    /// by code.
    public private(set) var learned: [String: Learned] = [:]

    public init() {}

    /// The rate to count on for a charger of this class: what has been learned, or the guess.
    public func rate(for band: Band) -> Double {
        learned[band.rawValue]?.rate ?? Self.defaultRate(for: band)
    }

    public func rate(forAdapterWatts watts: Double?) -> Double {
        rate(for: Self.band(forAdapterWatts: watts))
    }

    /// Whether anything has been learned for this band.
    public func hasLearned(_ band: Band) -> Bool { learned[band.rawValue] != nil }

    /// Fold one measurement into the band's average. A rate that is not a positive number (a battery that lost charge
    /// while "charging", a gauge that jumped) is no measurement and is dropped; one that is, is clamped to
    /// `ChargePolicy.chargeRateRange`, so a nonsense reading never becomes the estimate. True when it was taken.
    @discardableResult
    public mutating func record(_ measured: Double, for band: Band) -> Bool {
        guard measured.isFinite, measured > 0 else { return false }
        let r = min(max(measured, ChargePolicy.chargeRateRange.lowerBound), ChargePolicy.chargeRateRange.upperBound)
        guard var l = learned[band.rawValue] else {
            learned[band.rawValue] = Learned(rate: r, samples: 1)
            return true
        }
        let n = min(l.samples + 1, Self.averagedOver)
        l.rate += (r - l.rate) / Double(n)
        l.samples = n
        learned[band.rawValue] = l
        return true
    }

    /// What was stored, made safe to use: a band this build does not know is dropped, a rate is clamped, a count is
    /// brought inside 1 to `averagedOver`, and one that is not a number is dropped. The plist is also written by
    /// `defaults write` and by other builds.
    func sanitized() -> ChargeRate {
        var out = ChargeRate()
        for (key, l) in learned where Band(rawValue: key) != nil {
            guard l.rate.isFinite, l.rate > 0 else { continue }
            out.learned[key] = Learned(
                rate: min(max(l.rate, ChargePolicy.chargeRateRange.lowerBound), ChargePolicy.chargeRateRange.upperBound),
                samples: min(max(l.samples, 1), Self.averagedOver))
        }
        return out
    }
}

/// Watches the battery as the controller sees it, tick by tick, and says how fast it charged over each stretch long
/// enough to tell.
///
/// A stretch is a run of observations with a charger on the cable, the battery charging, and the charge between 20 and
/// 80%, of one class of charger, no further apart than `maxGap`. It is measured as soon as it is five minutes long,
/// and a new one begins where it ended, so a long charge gives a measurement every five minutes or so. One that ends
/// before it is five minutes long is nothing. A gap longer than `maxGap` (a sleep, a stopped app) ends a stretch
/// without being part of it: what the battery did while nobody looked is not what it did when somebody did.
public struct ChargeRateMeter {

    /// One measurement: a class of charger, and the rate in percent per minute. Not yet checked for sense:
    /// `ChargeRate.record` does that.
    public struct Measurement: Equatable {
        public var band: ChargeRate.Band
        public var rate: Double
    }

    /// The longest between two observations for them to be one stretch. The controller looks every 30 s.
    public static let maxGap: TimeInterval = 120

    private struct Point {
        var percent: Int
        var at: Date
    }
    private var start: Point?
    private var last: Point?
    private var band: ChargeRate.Band = .under30

    public init() {}

    /// Whether a stretch is under way.
    public var isMeasuring: Bool { start != nil }

    /// Note what the battery is doing now. Returns a measurement when this observation completes one.
    public mutating func observe(percent: Int, charging: Bool, onAC: Bool, adapterWatts: Double?, at now: Date)
        -> Measurement? {
        let thisBand = ChargeRate.band(forAdapterWatts: adapterWatts)
        let counts = onAC && charging && ChargeRate.measuredPercent.contains(percent)

        if let s = start, let l = last {
            let continues = counts && thisBand == band && now >= l.at && now.timeIntervalSince(l.at) <= Self.maxGap
            if continues {
                last = Point(percent: percent, at: now)
                guard now.timeIntervalSince(s.at) >= ChargeRate.minimumSpan else { return nil }
                // The next stretch begins where this one ended.
                start = last
                return measure(from: s, to: Point(percent: percent, at: now))
            }
            start = nil
            last = nil
        }
        if counts {
            start = Point(percent: percent, at: now)
            last = start
            band = thisBand
        }
        return nil
    }

    private func measure(from a: Point, to b: Point) -> Measurement? {
        let minutes = b.at.timeIntervalSince(a.at) / 60
        guard minutes > 0 else { return nil }
        return Measurement(band: band, rate: Double(b.percent - a.percent) / minutes)
    }
}

/// Where what is learned is kept between runs. A protocol so a test can hold it in memory and so that the real one,
/// which writes to the app's settings, is only ever given the settings it is to write to.
public protocol ChargeRateStore: AnyObject {
    func load() -> ChargeRate
    func save(_ rates: ChargeRate)
}

/// The real store: the JSON of a `ChargeRate` in `Settings.chargeRateRecord`.
public final class SettingsChargeRateStore: ChargeRateStore {
    private let settings: Settings

    public init(settings: Settings) {
        self.settings = settings
    }

    /// Nothing learned when nothing is stored, or what is stored cannot be read.
    public func load() -> ChargeRate {
        guard let text = settings.chargeRateRecord,
              let rates = try? JSONDecoder().decode(ChargeRate.self, from: Data(text.utf8)) else { return ChargeRate() }
        return rates.sanitized()
    }

    public func save(_ rates: ChargeRate) {
        guard let data = try? JSONEncoder().encode(rates), let text = String(data: data, encoding: .utf8) else { return }
        settings.chargeRateRecord = text
    }
}
