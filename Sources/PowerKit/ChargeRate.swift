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

    /// The two stretches of a charge that are learned apart, because a battery charges at two speeds: steadily up to
    /// 80%, and then slower and slower (`taper`). The policy counted the second as half the first, which on the one
    /// night it mattered was too fast (see `ChargePolicy.chargeTaperFactor`); what this Mac and this charger really
    /// do is measured instead.
    public enum Stretch: String, Codable, CaseIterable {
        case steady
        case taper
    }

    /// The steady rate is learned only between these charges: below it a battery may be trickling, and above it the
    /// charge tapers.
    public static let measuredPercent = 20...80
    /// The taper's rate is learned between these. The last few points above it go slower again and take too long for
    /// a measurement of whole percents to say much; the policy counts them at a share of this rate
    /// (`ChargePolicy.chargeTopOffFactor`).
    public static let measuredTaperPercent = 80...95

    /// The charges a stretch is measured between.
    public static func measured(_ stretch: Stretch) -> ClosedRange<Int> {
        stretch == .steady ? measuredPercent : measuredTaperPercent
    }

    /// The stretch a measurement starting at this charge belongs to; nil where nothing is learned.
    public static func stretch(startingAt percent: Int) -> Stretch? {
        if percent < measuredPercent.lowerBound || percent > measuredTaperPercent.upperBound { return nil }
        return percent < measuredPercent.upperBound ? .steady : .taper
    }
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
    /// The same for the taper, above 80%. Empty until a charge has gone through it with Anode looking.
    public private(set) var learnedAbove80: [String: Learned] = [:]

    public init() {}

    private enum CodingKeys: String, CodingKey { case learned, learnedAbove80 }

    /// What an earlier build stored has no taper in it: that is nothing learned for it, not a record that cannot be read.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        learned = try c.decodeIfPresent([String: Learned].self, forKey: .learned) ?? [:]
        learnedAbove80 = try c.decodeIfPresent([String: Learned].self, forKey: .learnedAbove80) ?? [:]
    }

    /// The rate above 80% for a charger of this class, when it has been learned; nil until then, and the policy
    /// counts a share of the steady rate.
    public func rateAbove80(for band: Band) -> Double? { learnedAbove80[band.rawValue]?.rate }

    public func rateAbove80(forAdapterWatts watts: Double?) -> Double? {
        rateAbove80(for: Self.band(forAdapterWatts: watts))
    }

    /// The slowest a taper is believed to be: the slowest charger there is, at the share the policy guesses.
    public static let slowestTaper = ChargePolicy.chargeRateRange.lowerBound * ChargePolicy.chargeTaperFactor

    /// The rate to count on for a charger of this class: what has been learned, or the guess.
    public func rate(for band: Band) -> Double {
        learned[band.rawValue]?.rate ?? Self.defaultRate(for: band)
    }

    public func rate(forAdapterWatts watts: Double?) -> Double {
        rate(for: Self.band(forAdapterWatts: watts))
    }

    /// Whether anything has been learned for this band.
    public func hasLearned(_ band: Band) -> Bool { learned[band.rawValue] != nil }

    /// The most a measurement may move the rate in one step, as a factor up or down. A gauge that jumps, a span that
    /// caught a taper or a plug-in make single measurements that are far from the truth, and an overestimate is the
    /// dangerous direction (the charge starts late); an underestimate only starts it early. So no one measurement is
    /// believed beyond this: the first is bounded around the band's guess, a later one around the average so far.
    public static let stepFactor = 1.5

    /// Fold one measurement into the band's average. A rate that is not a positive number (a battery that lost charge
    /// while "charging", a gauge that jumped) is no measurement and is dropped, and so is one above the fastest a
    /// charger gives (`ChargePolicy.chargeRateRange`), which says nothing about the charger. One that is left is
    /// bounded to within `stepFactor` of the rate now counted on (the band's guess, before anything is learned) and kept
    /// inside the range. True when it was taken.
    ///
    /// A measurement of the taper is folded into the taper's own average by the same rules, bounded around what the
    /// policy would otherwise count (`ChargePolicy.chargeTaperFactor` of the steady rate) until one has been taken.
    @discardableResult
    public mutating func record(_ measured: Double, for band: Band, stretch: Stretch = .steady) -> Bool {
        guard measured.isFinite, measured > 0, measured <= ChargePolicy.chargeRateRange.upperBound else { return false }
        let taper = stretch == .taper
        let basis = taper ? rateAbove80(for: band) ?? rate(for: band) * ChargePolicy.chargeTaperFactor : rate(for: band)
        let bounded = min(max(measured, basis / Self.stepFactor), basis * Self.stepFactor)
        let slowest = taper ? Self.slowestTaper : ChargePolicy.chargeRateRange.lowerBound
        let r = min(max(bounded, slowest), ChargePolicy.chargeRateRange.upperBound)
        var l = (taper ? learnedAbove80 : learned)[band.rawValue] ?? Learned(rate: r, samples: 0)
        let n = min(l.samples + 1, Self.averagedOver)
        l.rate += (r - l.rate) / Double(n)
        l.samples = n
        if taper { learnedAbove80[band.rawValue] = l } else { learned[band.rawValue] = l }
        return true
    }

    /// What was stored, made safe to use: a band this build does not know is dropped, a rate is clamped, a count is
    /// brought inside 1 to `averagedOver`, and one that is not a number is dropped. The plist is also written by
    /// `defaults write` and by other builds.
    func sanitized() -> ChargeRate {
        func safe(_ stored: [String: Learned], slowest: Double) -> [String: Learned] {
            var out: [String: Learned] = [:]
            for (key, l) in stored where Band(rawValue: key) != nil {
                guard l.rate.isFinite, l.rate > 0 else { continue }
                out[key] = Learned(rate: min(max(l.rate, slowest), ChargePolicy.chargeRateRange.upperBound),
                                   samples: min(max(l.samples, 1), Self.averagedOver))
            }
            return out
        }
        var out = ChargeRate()
        out.learned = safe(learned, slowest: ChargePolicy.chargeRateRange.lowerBound)
        out.learnedAbove80 = safe(learnedAbove80, slowest: Self.slowestTaper)
        return out
    }
}

/// Watches the battery as the controller sees it, tick by tick, and says how fast it charged over each stretch long
/// enough to tell.
///
/// A stretch is a run of observations with a charger on the cable, the battery charging, and the charge inside one of
/// the two ranges that are learned (20 to 80%, the steady charge, or 80 to 95%, the taper: `ChargeRate.Stretch`), of
/// one class of charger, no further apart than `maxGap`. A charge that crosses 80% ends the steady stretch there, and
/// the taper's begins with the next observation. It is measured as soon as it is five minutes long,
/// and a new one begins where it ended, so a long charge gives a measurement every five minutes or so. One that ends
/// before it is five minutes long is nothing. A gap longer than `maxGap` (a sleep, a stopped app) ends a stretch
/// without being part of it: what the battery did while nobody looked is not what it did when somebody did.
public struct ChargeRateMeter {

    /// One measurement: a class of charger, and the rate in percent per minute. Not yet checked for sense:
    /// `ChargeRate.record` does that.
    public struct Measurement: Equatable {
        public var band: ChargeRate.Band
        public var rate: Double
        /// Which of the two rates this is a measurement of.
        public var stretch: ChargeRate.Stretch = .steady
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
    private var stretch: ChargeRate.Stretch = .steady

    public init() {}

    /// Whether a stretch is under way.
    public var isMeasuring: Bool { start != nil }

    /// Note what the battery is doing now. Returns a measurement when this observation completes one.
    public mutating func observe(percent: Int, charging: Bool, onAC: Bool, adapterWatts: Double?, at now: Date)
        -> Measurement? {
        let thisBand = ChargeRate.band(forAdapterWatts: adapterWatts)
        let live = onAC && charging

        if let s = start, let l = last {
            let continues = live && ChargeRate.measured(stretch).contains(percent) && thisBand == band
                && now >= l.at && now.timeIntervalSince(l.at) <= Self.maxGap
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
        if live, let begins = ChargeRate.stretch(startingAt: percent) {
            start = Point(percent: percent, at: now)
            last = start
            band = thisBand
            stretch = begins
        }
        return nil
    }

    private func measure(from a: Point, to b: Point) -> Measurement? {
        let minutes = b.at.timeIntervalSince(a.at) / 60
        guard minutes > 0 else { return nil }
        return Measurement(band: band, rate: Double(b.percent - a.percent) / minutes, stretch: stretch)
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
