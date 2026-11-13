import XCTest
@testable import PowerKit

/// How fast a charger charges this Mac, learned for Ready By: the bands, the guesses, what counts as a measurement,
/// what a nonsense one does, and what survives a quit. Nothing here reaches the Mac: the meter is fed values, and the
/// store is either a dictionary in memory or a throwaway settings suite.
final class ChargeRateTests: XCTestCase {

    // ── Bands ───────────────────────────────────────────────────────────────

    func testBandsByRatedPowerAndTheirEdges() {
        typealias B = ChargeRate.Band
        XCTAssertEqual(ChargeRate.band(forAdapterWatts: 5), B.under30)
        XCTAssertEqual(ChargeRate.band(forAdapterWatts: 20), B.under30)
        XCTAssertEqual(ChargeRate.band(forAdapterWatts: 29), B.under30)
        XCTAssertEqual(ChargeRate.band(forAdapterWatts: 29.9), B.under30)
        XCTAssertEqual(ChargeRate.band(forAdapterWatts: 30), B.from30to65, "30 is in the middle band")
        XCTAssertEqual(ChargeRate.band(forAdapterWatts: 45), B.from30to65)
        XCTAssertEqual(ChargeRate.band(forAdapterWatts: 61), B.from30to65)
        XCTAssertEqual(ChargeRate.band(forAdapterWatts: 65), B.from30to65, "65 is in the middle band")
        XCTAssertEqual(ChargeRate.band(forAdapterWatts: 65.1), B.over65)
        XCTAssertEqual(ChargeRate.band(forAdapterWatts: 67), B.over65)
        XCTAssertEqual(ChargeRate.band(forAdapterWatts: 100), B.over65)
        XCTAssertEqual(ChargeRate.band(forAdapterWatts: 140), B.over65)
    }

    /// A charger that does not say what it is, is taken for the slowest: it starts early and not late.
    func testAChargerThatSaysNothingIsTheSlowestClass() {
        for w in [nil, 0, -5, Double.nan, Double.infinity] as [Double?] {
            XCTAssertEqual(ChargeRate.band(forAdapterWatts: w), .under30, "\(String(describing: w))")
        }
    }

    func testTheGuessesUntilSomethingIsLearned() {
        let r = ChargeRate()
        XCTAssertEqual(r.rate(for: .under30), 0.3)
        XCTAssertEqual(r.rate(for: .from30to65), 0.8)
        XCTAssertEqual(r.rate(for: .over65), 1.0)
        XCTAssertEqual(r.rate(forAdapterWatts: 100), 1.0)
        XCTAssertEqual(r.rate(forAdapterWatts: 30), 0.8)
        XCTAssertEqual(r.rate(forAdapterWatts: nil), 0.3)
        XCTAssertFalse(r.hasLearned(.over65))
    }

    // ── What is learned ─────────────────────────────────────────────────────

    func testTheFirstMeasurementIsTheRateAndTheNextAreAveragedIn() {
        var r = ChargeRate()
        XCTAssertTrue(r.record(1.3, for: .over65))
        XCTAssertEqual(r.rate(for: .over65), 1.3, accuracy: 1e-12)
        XCTAssertTrue(r.hasLearned(.over65))
        XCTAssertTrue(r.record(1.1, for: .over65))
        XCTAssertEqual(r.rate(for: .over65), 1.2, accuracy: 1e-12, "the mean of the two")
        XCTAssertTrue(r.record(1.5, for: .over65))
        XCTAssertEqual(r.rate(for: .over65), (1.3 + 1.1 + 1.5) / 3, accuracy: 1e-12)
    }

    /// What one band learns is not another's.
    func testBandsLearnApart() {
        var r = ChargeRate()
        r.record(1.4, for: .over65)
        XCTAssertEqual(r.rate(for: .from30to65), 0.8, "the middle band was never measured")
        XCTAssertEqual(r.rate(for: .under30), 0.3)
        r.record(0.6, for: .from30to65)
        XCTAssertEqual(r.rate(for: .over65), 1.4)
        XCTAssertEqual(r.rate(for: .from30to65), 0.6)
    }

    /// One bad first sample started the charge hours late: a gauge that jumped 15 points in five minutes is 3.0 a minute
    /// on a charger that charges at 0.3, and the first measurement for a band replaced the guess outright. A measurement
    /// moves the rate by a factor of 1.5 at most, up or down, so the first is bounded around the band's guess.
    func testTheFirstMeasurementIsBoundedAroundTheGuess() {
        var slow = ChargeRate()
        XCTAssertTrue(slow.record(3.0, for: .under30), "3.0 a minute is not more than 3")
        XCTAssertEqual(slow.rate(for: .under30), 0.3 * 1.5, accuracy: 1e-12, "the guess times 1.5, not the jump")
        var fast = ChargeRate()
        XCTAssertTrue(fast.record(0.2, for: .over65))
        XCTAssertEqual(fast.rate(for: .over65), 1.0 / 1.5, accuracy: 1e-12, "the guess over 1.5, not the dip")
        var inside = ChargeRate()
        inside.record(1.3, for: .over65)
        XCTAssertEqual(inside.rate(for: .over65), 1.3, accuracy: 1e-12, "a believable first sample is taken as it is")
    }

    /// An average that took twenty measurements to build is not pulled far by one: the measurement is bounded around it
    /// first, and then averaged in.
    func testAnEstablishedAverageCannotBeYanked() {
        var r = ChargeRate()
        for _ in 0..<ChargeRate.averagedOver { r.record(1.0, for: .over65) }
        r.record(3.0, for: .over65)
        XCTAssertEqual(r.rate(for: .over65), 1.0 + (1.5 - 1.0) / Double(ChargeRate.averagedOver), accuracy: 1e-12)
        var low = ChargeRate()
        for _ in 0..<ChargeRate.averagedOver { low.record(1.0, for: .over65) }
        low.record(0.1, for: .over65)
        XCTAssertEqual(low.rate(for: .over65), 1.0 + (1.0 / 1.5 - 1.0) / Double(ChargeRate.averagedOver), accuracy: 1e-12)
    }

    /// A span in which the charge rose by more than a charger can give for its length is a misreading and is dropped,
    /// not clamped to the fastest there is: it says nothing about the charger.
    func testAMeasurementAboveThreeAMinuteIsDroppedNotClamped() {
        var r = ChargeRate()
        XCTAssertFalse(r.record(3.5, for: .over65))
        XCTAssertFalse(r.record(9, for: .under30))
        XCTAssertFalse(r.hasLearned(.over65))
        XCTAssertFalse(r.hasLearned(.under30))
        XCTAssertEqual(r.rate(for: .over65), 1.0, "still the guess")
        r.record(1.2, for: .over65)
        XCTAssertFalse(r.record(3.0000001, for: .over65))
        XCTAssertEqual(r.rate(for: .over65), 1.2, accuracy: 1e-12, "and an estimate is not touched by one")
        for band in ChargeRate.Band.allCases {
            XCTAssertTrue(ChargePolicy.chargeRateRange.contains(r.rate(for: band)), "\(band)")
        }
    }

    func testNonsenseIsNotAMeasurement() {
        var r = ChargeRate()
        for bad in [Double.nan, .infinity, -.infinity, 0, -0.5] {
            XCTAssertFalse(r.record(bad, for: .over65), "\(bad)")
        }
        XCTAssertFalse(r.hasLearned(.over65))
        XCTAssertEqual(r.rate(for: .over65), 1.0, "still the guess")
        r.record(1.2, for: .over65)
        r.record(.nan, for: .over65)
        XCTAssertEqual(r.rate(for: .over65), 1.2, accuracy: 1e-12, "and an estimate is not spoilt by one")
    }

    /// A running average, not an ever-slower one: the last twenty count, so a charger that changes is followed.
    func testTheAverageFollowsTheLastTwentyMeasurements() {
        var r = ChargeRate()
        for _ in 0..<200 { r.record(1.0, for: .over65) }
        XCTAssertEqual(r.learned["over65"]?.samples, ChargeRate.averagedOver)
        for _ in 0..<200 { r.record(2.0, for: .over65) }
        XCTAssertEqual(r.rate(for: .over65), 2.0, accuracy: 0.001, "a swap of charger is learned within a few charges")
    }

    func testTheRangeIsTheSameOneThePolicyBelieves() {
        XCTAssertEqual(ChargePolicy.chargeRateRange, 0.1...3.0)
        XCTAssertEqual(ChargeRate.measuredPercent, 20...80)
        XCTAssertEqual(ChargeRate.minimumSpan, 300)
    }

    // ── The meter ───────────────────────────────────────────────────────────

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// Steady charging at `perMinute` from `from`, observed every 30 s, with the battery's whole percents.
    private func feed(_ m: inout ChargeRateMeter, from: Double, perMinute: Double, minutes: Double, startingAt start: Date? = nil,
                      charging: Bool = true, onAC: Bool = true, watts: Double? = 100) -> [ChargeRateMeter.Measurement] {
        var out: [ChargeRateMeter.Measurement] = []
        let t = start ?? t0
        var s = 0.0
        while s <= minutes * 60 {
            let p = Int((from + perMinute * s / 60).rounded(.down))
            if let x = m.observe(percent: p, charging: charging, onAC: onAC, adapterWatts: watts,
                                 at: t.addingTimeInterval(s)) {
                out.append(x)
            }
            s += 30
        }
        return out
    }

    func testASteadyChargeIsMeasuredOverFiveMinutes() {
        var m = ChargeRateMeter()
        let out = feed(&m, from: 40, perMinute: 1.0, minutes: 5)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.band, .over65)
        XCTAssertEqual(out.first?.rate ?? 0, 1.0, accuracy: 0.05)
    }

    func testUnderFiveMinutesIsNotMeasured() {
        var m = ChargeRateMeter()
        let out = feed(&m, from: 40, perMinute: 1.0, minutes: 4.5)
        XCTAssertTrue(out.isEmpty, "4.5 minutes is too short")
        // And one that then ends is no measurement either.
        XCTAssertNil(m.observe(percent: 46, charging: false, onAC: true, adapterWatts: 100,
                               at: t0.addingTimeInterval(5 * 60 - 10)))
    }

    func testALongChargeIsMeasuredEveryFiveMinutes() {
        var m = ChargeRateMeter()
        let out = feed(&m, from: 20, perMinute: 1.2, minutes: 30)
        XCTAssertEqual(out.count, 6, "thirty minutes is six stretches of five")
        for x in out { XCTAssertEqual(x.rate, 1.2, accuracy: 0.25) }
    }

    func testOnlyChargingBetweenTwentyAndEightyCounts() {
        var m = ChargeRateMeter()
        XCTAssertTrue(feed(&m, from: 81, perMinute: 0.5, minutes: 20).isEmpty, "above 80: tapering")
        m = ChargeRateMeter()
        XCTAssertTrue(feed(&m, from: 5, perMinute: 0.5, minutes: 20).isEmpty, "below 20")
        m = ChargeRateMeter()
        XCTAssertTrue(feed(&m, from: 50, perMinute: 1, minutes: 20, charging: false).isEmpty, "not charging")
        m = ChargeRateMeter()
        XCTAssertTrue(feed(&m, from: 50, perMinute: 1, minutes: 20, onAC: false).isEmpty, "no charger")
        // The edges themselves are inside.
        m = ChargeRateMeter()
        XCTAssertEqual(feed(&m, from: 20, perMinute: 0.2, minutes: 5).count, 1, "20% counts")
        m = ChargeRateMeter()
        XCTAssertEqual(feed(&m, from: 74, perMinute: 1.2, minutes: 5).count, 1, "74 to 80% counts")
    }

    /// A stretch that climbs out of the band is measured up to where it left it, and not a point further.
    func testALeavingTheBandEndsTheStretchWhereItLeft() {
        var m = ChargeRateMeter()
        var out: [ChargeRateMeter.Measurement] = []
        // 70 at 1 a minute: 80 is reached at ten minutes; 81 at eleven.
        for s in stride(from: 0.0, through: 11 * 60, by: 30) {
            let p = 70 + Int((s / 60).rounded(.down))
            if let x = m.observe(percent: p, charging: true, onAC: true, adapterWatts: 100, at: t0.addingTimeInterval(s)) {
                out.append(x)
            }
        }
        XCTAssertEqual(out.count, 2, "five minutes, then five more up to 80, and the step to 81 is not one")
        for x in out { XCTAssertEqual(x.rate, 1.0, accuracy: 0.05) }
        XCTAssertFalse(m.isMeasuring)
    }

    /// A sleep or a stopped app is not charging that was watched.
    func testAGapEndsTheStretchAndIsNotMeasured() {
        var m = ChargeRateMeter()
        _ = m.observe(percent: 50, charging: true, onAC: true, adapterWatts: 100, at: t0)
        _ = m.observe(percent: 50, charging: true, onAC: true, adapterWatts: 100, at: t0.addingTimeInterval(30))
        // An hour later, ten points up: 0.17 a minute, which is the sleep and not the charger.
        let after = m.observe(percent: 60, charging: true, onAC: true, adapterWatts: 100,
                              at: t0.addingTimeInterval(3630))
        XCTAssertNil(after)
        // The new stretch starts there: five minutes later it is measured on its own.
        var out: [ChargeRateMeter.Measurement] = []
        for s in stride(from: 30.0, through: 300, by: 30) {
            let p = 60 + Int((s / 60).rounded(.down))
            if let x = m.observe(percent: p, charging: true, onAC: true, adapterWatts: 100,
                                 at: t0.addingTimeInterval(3630 + s)) { out.append(x) }
        }
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.rate ?? 0, 1.0, accuracy: 0.05)
    }

    func testAChangeOfChargerStartsAFreshStretchInItsOwnBand() {
        var m = ChargeRateMeter()
        _ = feed(&m, from: 40, perMinute: 1, minutes: 3, watts: 100)
        XCTAssertTrue(m.isMeasuring)
        // A 30 W charger from here: the three minutes on the first one are not counted for it.
        let out = feed(&m, from: 43, perMinute: 0.5, minutes: 5, startingAt: t0.addingTimeInterval(3 * 60 + 30),
                       watts: 30)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.band, .from30to65)
        XCTAssertEqual(out.first?.rate ?? 0, 0.5, accuracy: 0.1)
    }

    /// The meter reports; it does not judge. A battery that lost charge while charging is reported as the nonsense it
    /// is, and `ChargeRate.record` is what refuses it.
    func testALossWhileChargingIsReportedAsNonsenseNotDropped() {
        var m = ChargeRateMeter()
        var x: ChargeRateMeter.Measurement?
        for s in stride(from: 0.0, through: 300, by: 30) {
            let p = s < 300 ? 50 : 48
            x = m.observe(percent: p, charging: true, onAC: true, adapterWatts: 100, at: t0.addingTimeInterval(s)) ?? x
        }
        XCTAssertEqual(x?.rate ?? 1, -0.4, accuracy: 1e-9)
        var r = ChargeRate()
        XCTAssertFalse(r.record(x?.rate ?? 0, for: x?.band ?? .over65))
    }

    // ── What survives a quit ────────────────────────────────────────────────

    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        (defaults, suite) = try TestDefaults.make(owner: "ChargeRate", test: name)
    }

    override func tearDownWithError() throws {
        TestDefaults.destroy(defaults, suite)
    }

    func testWhatIsLearnedIsStoredAndComesBack() {
        let s = Settings(defaults: defaults)
        let store = SettingsChargeRateStore(settings: s)
        XCTAssertEqual(store.load(), ChargeRate(), "nothing stored: nothing learned")
        var r = ChargeRate()
        r.record(1.25, for: .over65)
        r.record(0.7, for: .from30to65)
        r.record(0.7, for: .from30to65)
        store.save(r)
        let again = SettingsChargeRateStore(settings: Settings(defaults: defaults)).load()
        XCTAssertEqual(again, r)
        XCTAssertEqual(again.rate(for: .over65), 1.25, accuracy: 1e-12)
        XCTAssertEqual(again.learned["from30to65"]?.samples, 2)
        XCTAssertFalse(again.hasLearned(.under30))
    }

    /// It goes to the settings it was given, under its own key, and nothing that is observed hears of it.
    func testItIsStoredInTheSettingsItWasGivenAndNotifiesNobody() {
        let s = Settings(defaults: defaults)
        var fired = 0
        let token = s.observe(Settings.Key.any) { fired += 1 }
        var r = ChargeRate()
        r.record(1.0, for: .over65)
        SettingsChargeRateStore(settings: s).save(r)
        XCTAssertEqual(fired, 0)
        XCTAssertNotNil(defaults.object(forKey: "anode.chargeRateRecord") as? String)
        _ = token
    }

    func testAStoredRecordThatCannotBeReadIsNothingLearned() {
        for junk in ["", "{", "[1,2]", "null", #"{"learned":"x"}"#, #"{"learned":{"over65":{"rate":"fast"}}}"#] {
            defaults.set(junk, forKey: "anode.chargeRateRecord")
            XCTAssertEqual(SettingsChargeRateStore(settings: Settings(defaults: defaults)).load(), ChargeRate(), junk)
        }
        defaults.set(42, forKey: "anode.chargeRateRecord")
        XCTAssertEqual(SettingsChargeRateStore(settings: Settings(defaults: defaults)).load(), ChargeRate(),
                       "a number is not a record")
    }

    /// The plist is also written by `defaults write` and by other builds: what is read is made safe before it is used.
    func testAStoredRecordIsMadeSafeOnTheWayIn() {
        defaults.set(#"""
        {"learned":{
          "over65":{"rate":99,"samples":5},
          "from30to65":{"rate":0.0001,"samples":-4},
          "under30":{"rate":0.5,"samples":9999},
          "other":{"rate":1,"samples":1}}}
        """#, forKey: "anode.chargeRateRecord")
        let r = SettingsChargeRateStore(settings: Settings(defaults: defaults)).load()
        XCTAssertEqual(r.rate(for: .over65), 3, "clamped")
        XCTAssertEqual(r.rate(for: .from30to65), 0.1, "clamped")
        XCTAssertEqual(r.learned["from30to65"]?.samples, 1)
        XCTAssertEqual(r.learned["under30"]?.samples, ChargeRate.averagedOver)
        XCTAssertNil(r.learned["other"], "a class this build does not know is dropped")
        defaults.set(#"{"learned":{"over65":{"rate":0,"samples":3}}}"#, forKey: "anode.chargeRateRecord")
        XCTAssertFalse(SettingsChargeRateStore(settings: Settings(defaults: defaults)).load().hasLearned(.over65),
                       "a rate of nothing is not learned")
    }

    func testAnythingButAStringUnderTheKeyIsNoRecord() {
        defaults.set(42, forKey: "anode.chargeRateRecord")
        XCTAssertNil(Settings(defaults: defaults).chargeRateRecord)
        defaults.set(Data([1]), forKey: "anode.chargeRateRecord")
        XCTAssertNil(Settings(defaults: defaults).chargeRateRecord)
        let s = Settings(defaults: defaults)
        s.chargeRateRecord = "{}"
        XCTAssertEqual(s.chargeRateRecord, "{}")
        s.chargeRateRecord = nil
        XCTAssertNil(defaults.object(forKey: "anode.chargeRateRecord"), "cleared means the key is gone")
    }

    // ── The charger's rated power ───────────────────────────────────────────

    func testAdapterWattsReadFromTheAdapterDetails() {
        XCTAssertEqual(Battery.adapterWatts(fromProperties: ["AdapterDetails": ["Watts": 100, "AdapterVoltage": 20000]]), 100)
        XCTAssertEqual(Battery.adapterWatts(fromProperties: ["AdapterDetails": ["Watts": 29.5]]), 29.5)
        XCTAssertEqual(Battery.adapterWatts(fromProperties: ["AdapterDetails": ["Watts": NSNumber(value: 67)]]), 67)
    }

    func testNoWattsMeansNil() {
        XCTAssertNil(Battery.adapterWatts(fromProperties: [:]))
        XCTAssertNil(Battery.adapterWatts(fromProperties: ["AdapterDetails": ["FamilyCode": 0]]), "the cable is out")
        XCTAssertNil(Battery.adapterWatts(fromProperties: ["AdapterDetails": [String: Any]()]))
        XCTAssertNil(Battery.adapterWatts(fromProperties: ["AdapterDetails": "100 W"]))
        XCTAssertNil(Battery.adapterWatts(fromProperties: ["AdapterDetails": [100, 20000]]))
        XCTAssertNil(Battery.adapterWatts(fromProperties: ["AdapterDetails": NSNull()]))
        XCTAssertNil(Battery.adapterWatts(fromProperties: ["AdapterDetails": ["Watts": "100"]]))
        XCTAssertNil(Battery.adapterWatts(fromProperties: ["AdapterDetails": ["Watts": 0]]))
        XCTAssertNil(Battery.adapterWatts(fromProperties: ["AdapterDetails": ["Watts": -30]]))
        XCTAssertNil(Battery.adapterWatts(fromProperties: ["AdapterDetails": ["Watts": Double.nan]]))
        XCTAssertNil(Battery.adapterWatts(fromProperties: ["AdapterDetails": ["Watts": Double.infinity]]))
    }

    /// A registry boolean bridges to NSNumber, and `true` would read as a 1 W charger.
    func testABooleanIsNotAWattage() {
        XCTAssertNil(Battery.adapterWatts(fromProperties: ["AdapterDetails": ["Watts": true]]))
        XCTAssertNil(Battery.adapterWatts(fromProperties: ["AdapterDetails": ["Watts": false]]))
    }

    func testAStateFixtureCarriesNoWattsUnlessGivenSome() {
        let s = Battery.State(percent: 50, isCharging: true, onAC: true, cycleCount: 1, voltage_mV: 12_000,
                              amperage_mA: 0, remainingCapacity_mAh: 1, timeRemaining_min: nil)
        XCTAssertNil(s.adapterWatts)
    }
}
