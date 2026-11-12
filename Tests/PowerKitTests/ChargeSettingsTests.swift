import XCTest
@testable import PowerKit

/// Charge Control's settings: the switch, the limit, the four feature switches with their two numbers, and the record
/// of how macOS's own charging was set before Charge Control changed it.
///
/// The three numbers get more tests than the switches because they do not stop at the screen. The limit becomes
/// macOS's charge limit and the maximum temperature decides whether the battery charges at all, so a number that is
/// out of range, of the wrong type or not a number has to be stopped here whichever way it arrived: from the UI, from
/// `defaults write`, or from a plist some other build left behind.
final class ChargeSettingsTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        (defaults, suiteName) = try TestDefaults.make(owner: "ChargeSettings", test: name)
    }

    override func tearDownWithError() throws {
        TestDefaults.destroy(defaults, suiteName)
    }

    /// What is on disk for a setting, read around `Settings`. The name is spelled out, never taken from
    /// `Settings.Key`: these strings are the storage format, and a rename would orphan what someone had set.
    private func stored(_ name: String) -> Any? { defaults.object(forKey: "anode." + name) }

    /// Put a value on disk the way `defaults write` or another build would: with no validation at all.
    private func store(_ value: Any, as name: String) { defaults.set(value, forKey: "anode." + name) }

    /// One observer per charge key on `s`, eight in all; each reports its short name when it fires. Retain the
    /// tokens: a released token unobserves.
    private func observeEveryChargeKey(of s: Settings, _ report: @escaping (String) -> Void) -> [AnyObject] {
        [(Settings.Key.chargeControlEnabled, "enabled"),
         (Settings.Key.chargeLimit, "limit"),
         (Settings.Key.chargeSailingEnabled, "sailing"),
         (Settings.Key.chargeSailingGap, "gap"),
         (Settings.Key.chargeHeatProtectionEnabled, "heat"),
         (Settings.Key.chargeMaxTemperatureC, "temperature"),
         (Settings.Key.chargeStopWhenSleeping, "sleeping"),
         (Settings.Key.chargeAutomaticDischarge, "automatic")]
            .map { key, name in s.observe(key) { report(name) } }
    }

    /// Move every observable charge setting off its default, in the order the observers above are listed.
    private func changeEverything(through s: Settings) {
        s.chargeControlEnabled = true
        s.chargeLimit = 63
        s.chargeSailingEnabled = true
        s.chargeSailingGap = 9
        s.chargeHeatProtectionEnabled = true
        s.chargeMaxTemperatureC = 41.5
        s.chargeStopWhenSleeping = true
        s.chargeAutomaticDischarge = true
    }

    // ── Defaults ────────────────────────────────────────────────────────────

    /// On a machine that has never seen Charge Control every switch is off, the numbers are charge to 80, sail 5
    /// below and pause at 35 °C, and nothing is recorded to put back because nothing has been changed.
    func testDefaults() {
        let s = Settings(defaults: defaults)
        XCTAssertFalse(s.chargeControlEnabled, "off until asked for: it changes macOS's own charge limit")
        XCTAssertEqual(s.chargeLimit, 80)
        XCTAssertFalse(s.chargeSailingEnabled)
        XCTAssertEqual(s.chargeSailingGap, 5)
        XCTAssertFalse(s.chargeHeatProtectionEnabled)
        XCTAssertEqual(s.chargeMaxTemperatureC, 35)
        XCTAssertFalse(s.chargeStopWhenSleeping)
        XCTAssertFalse(s.chargeAutomaticDischarge)
        XCTAssertNil(s.chargeRestoreRecord)
    }

    // ── Clamping on the way in ──────────────────────────────────────────────

    /// 5 becomes 20 and 150 becomes 100. What was stored is checked as well as what reads back: reading clamps too,
    /// so without that a setter which stored 150 untouched would pass.
    func testLimitClamps() {
        let s = Settings(defaults: defaults)
        s.chargeLimit = 5
        XCTAssertEqual(s.chargeLimit, 20)
        XCTAssertEqual(stored("chargeLimit") as? Int, 20)
        s.chargeLimit = 150
        XCTAssertEqual(s.chargeLimit, 100)
        XCTAssertEqual(stored("chargeLimit") as? Int, 100)
        s.chargeLimit = 63
        XCTAssertEqual(s.chargeLimit, 63, "a limit inside the range is kept as asked, to the percent")
        XCTAssertEqual(stored("chargeLimit") as? Int, 63)
        s.chargeLimit = Int.min
        XCTAssertEqual(s.chargeLimit, 20)
        s.chargeLimit = Int.max
        XCTAssertEqual(s.chargeLimit, 100)
    }

    func testGapAndTemperatureClamp() {
        let s = Settings(defaults: defaults)
        s.chargeSailingGap = 0
        XCTAssertEqual(s.chargeSailingGap, 1, "a gap of 0 leaves Sailing Mode no band to rest in")
        XCTAssertEqual(stored("chargeSailingGap") as? Int, 1)
        s.chargeSailingGap = 99
        XCTAssertEqual(s.chargeSailingGap, 30)
        XCTAssertEqual(stored("chargeSailingGap") as? Int, 30)
        s.chargeSailingGap = 7
        XCTAssertEqual(s.chargeSailingGap, 7)

        s.chargeMaxTemperatureC = 10
        XCTAssertEqual(s.chargeMaxTemperatureC, 25, "a maximum no pack is ever below would hold charging for good")
        XCTAssertEqual(stored("chargeMaxTemperatureC") as? Double, 25)
        s.chargeMaxTemperatureC = 80
        XCTAssertEqual(s.chargeMaxTemperatureC, 50)
        XCTAssertEqual(stored("chargeMaxTemperatureC") as? Double, 50)
        s.chargeMaxTemperatureC = 40.5
        XCTAssertEqual(s.chargeMaxTemperatureC, 40.5)
    }

    /// NaN and infinity cannot be clamped (every comparison with NaN is false), so a write of one is refused and the
    /// last good value stands.
    func testATemperatureThatIsNotANumberIsRefused() {
        let s = Settings(defaults: defaults)
        s.chargeMaxTemperatureC = 40.5
        s.chargeMaxTemperatureC = .nan
        XCTAssertEqual(s.chargeMaxTemperatureC, 40.5)
        s.chargeMaxTemperatureC = .infinity
        XCTAssertEqual(s.chargeMaxTemperatureC, 40.5)
        s.chargeMaxTemperatureC = -.infinity
        XCTAssertEqual(s.chargeMaxTemperatureC, 40.5)
        XCTAssertEqual(stored("chargeMaxTemperatureC") as? Double, 40.5)
    }

    /// Asking for 80 when 80 is already the default still writes it, and tells nobody (nothing changed). Otherwise
    /// "never chose" and "chose 80" are one state on disk, and a build with another default would move the limit of
    /// someone who had picked theirs.
    func testChoosingTheDefaultLimitIsStillRecorded() {
        let s = Settings(defaults: defaults)
        var fired = 0
        let token = s.observe(Settings.Key.chargeLimit) { fired += 1 }
        XCTAssertNil(stored("chargeLimit"))
        s.chargeLimit = 80
        XCTAssertEqual(stored("chargeLimit") as? Int, 80)
        XCTAssertEqual(fired, 0)
        _ = token
    }

    // ── Clamping on the way out ─────────────────────────────────────────────

    /// Values that reached the plist without passing through a setter. Out of range reads as the nearest end of the
    /// range; anything that is not a number, NaN and infinity included, reads as the default.
    ///
    /// The strings hold numbers that differ from the defaults on purpose: `defaults write … anode.chargeLimit 63`
    /// with no `-int` stores the STRING "63", and a read that quietly took it for 63 would pass a test whose string
    /// happened to hold the default.
    ///
    /// A Boolean is in the list because it is the one wrong type that looks like a number: it bridges to `NSNumber`,
    /// so a stored `true` read carelessly is 1, which clamps to a limit of 20 or a maximum temperature of 25 °C.
    ///
    /// Each case is stored on top of a good value that no case expects (50, 17, 30.5). A case that never reached the
    /// plist would then read as that value and fail, where over an empty key it would read as the default and pass.
    func testCorruptStoredValuesReadAsDefaultOrClamped() {
        let limits: [(stored: Any, want: Int)] = [
            (5, 20), (0, 20), (-40, 20), (150, 100), (Int.max, 100), (Int.min, 20),
            (63.4, 63), (63.6, 64), (1e300, 100), (-1e300, 20),
            ("63", 80), ("", 80), (Data([6, 3]), 80), ([63], 80), (["limit": 63], 80),
            (Date(timeIntervalSince1970: 63), 80), (true, 80), (false, 80),
            (Double.nan, 80), (Double.infinity, 80), (-Double.infinity, 80),
        ]
        for (raw, want) in limits {
            store(50, as: "chargeLimit")
            store(raw, as: "chargeLimit")
            XCTAssertEqual(Settings(defaults: defaults).chargeLimit, want, "chargeLimit stored as \(raw)")
        }

        let gaps: [(stored: Any, want: Int)] = [
            (0, 1), (-3, 1), (99, 30), (Int.max, 30), (1, 1), (30, 30), (12.4, 12),
            ("12", 5), (Data([1, 2]), 5), ([12], 5), (true, 5), (false, 5),
            (Double.nan, 5), (Double.infinity, 5), (-Double.infinity, 5),
        ]
        for (raw, want) in gaps {
            store(17, as: "chargeSailingGap")
            store(raw, as: "chargeSailingGap")
            XCTAssertEqual(Settings(defaults: defaults).chargeSailingGap, want, "chargeSailingGap stored as \(raw)")
        }

        let temperatures: [(stored: Any, want: Double)] = [
            (0, 25), (10.0, 25), (-5.5, 25), (80, 50), (500.5, 50), (25, 25), (50, 50), (41, 41), (41.5, 41.5),
            ("41", 35), (Data([4, 1]), 35), ([41.0], 35),
            (Date(timeIntervalSince1970: 41), 35), (true, 35), (false, 35),
            (Double.nan, 35), (Double.infinity, 35), (-Double.infinity, 35),
        ]
        for (raw, want) in temperatures {
            store(30.5, as: "chargeMaxTemperatureC")
            store(raw, as: "chargeMaxTemperatureC")
            XCTAssertEqual(Settings(defaults: defaults).chargeMaxTemperatureC, want,
                           "chargeMaxTemperatureC stored as \(raw)")
        }
    }

    // ── Persistence ─────────────────────────────────────────────────────────

    func testEnabledPersistsAcrossHandles() {
        Settings(defaults: defaults).chargeControlEnabled = true
        XCTAssertTrue(Settings(defaults: defaults).chargeControlEnabled)
    }

    /// Five switches, five keys. Each is turned on alone and must be the only one that reads on: two of them pasted
    /// onto one key would pass every test that only reads back the value it just wrote.
    func testEachSwitchIsStoredOnItsOwn() {
        let switches: [(name: String, path: ReferenceWritableKeyPath<Settings, Bool>)] = [
            ("chargeControlEnabled", \.chargeControlEnabled),
            ("chargeSailingEnabled", \.chargeSailingEnabled),
            ("chargeHeatProtectionEnabled", \.chargeHeatProtectionEnabled),
            ("chargeStopWhenSleeping", \.chargeStopWhenSleeping),
            ("chargeAutomaticDischarge", \.chargeAutomaticDischarge),
        ]
        let s = Settings(defaults: defaults)
        for (name, path) in switches {
            s[keyPath: path] = true
            let reader = Settings(defaults: defaults)
            XCTAssertEqual(switches.filter { reader[keyPath: $0.path] }.map(\.name), [name])
            XCTAssertEqual(stored(name) as? Bool, true)
            s[keyPath: path] = false
        }
    }

    func testNumbersPersistAcrossHandlesUnderTheirOwnKeys() {
        let s = Settings(defaults: defaults)
        s.chargeLimit = 63
        s.chargeSailingGap = 9
        s.chargeMaxTemperatureC = 41.5
        let again = Settings(defaults: defaults)
        XCTAssertEqual(again.chargeLimit, 63)
        XCTAssertEqual(again.chargeSailingGap, 9)
        XCTAssertEqual(again.chargeMaxTemperatureC, 41.5)
        XCTAssertEqual(stored("chargeLimit") as? Int, 63)
        XCTAssertEqual(stored("chargeSailingGap") as? Int, 9)
        XCTAssertEqual(stored("chargeMaxTemperatureC") as? Double, 41.5)
    }

    // ── Observation ─────────────────────────────────────────────────────────

    /// Each change tells its own key's observer, once. A second notification for one write is how a controller
    /// applies the same limit twice.
    func testChangeNotifiesObservers() {
        let s = Settings(defaults: defaults)
        var fired: [String] = []
        let tokens = observeEveryChargeKey(of: s) { fired.append($0) }

        changeEverything(through: s)
        XCTAssertEqual(fired, ["enabled", "limit", "sailing", "gap", "heat", "temperature", "sleeping", "automatic"])

        // The same values again tell nobody anything.
        fired = []
        changeEverything(through: s)
        XCTAssertEqual(fired, [])

        // Nor does a value that clamps to the one already there: 150 is 100, and 100 is what it is.
        s.chargeLimit = 100
        s.chargeLimit = 150
        XCTAssertEqual(fired, ["limit"])
        XCTAssertEqual(tokens.count, 8)
    }

    /// The controller watches these on its own `Settings`; the Beta Features window writes them through whichever
    /// handle it holds. `reconcile()` is what carries the change across, and a key left out of it fails silently:
    /// the value is stored, reads back correctly, and nothing in the running app reacts until the next launch.
    func testAWriteThroughAnotherHandleNotifiesObservers() {
        let watching = Settings(defaults: defaults)
        var fired: [String] = []
        let tokens = observeEveryChargeKey(of: watching) { fired.append($0) }

        changeEverything(through: Settings(defaults: defaults))

        XCTAssertEqual(fired, ["enabled", "limit", "sailing", "gap", "heat", "temperature", "sleeping", "automatic"])
        XCTAssertEqual(tokens.count, 8)
    }

    // ── The restore record ──────────────────────────────────────────────────

    /// It has to outlive the process that wrote it: a crash leaves the limit in force, so the way back to what macOS
    /// had before must still be there on the next launch, which is also how that launch knows the last run did not
    /// quit. Cleared means the key is gone, so "no record" is one state on disk and the next enable records afresh.
    func testRestoreRecordRoundTripsAndClears() {
        let record = #"{"mclEnabled":true,"mclLimit":90,"optimizedChargingEnabled":true}"#
        let s = Settings(defaults: defaults)
        s.chargeRestoreRecord = record
        XCTAssertEqual(s.chargeRestoreRecord, record)
        XCTAssertEqual(Settings(defaults: defaults).chargeRestoreRecord, record)
        XCTAssertEqual(stored("chargeRestoreRecord") as? String, record)

        s.chargeRestoreRecord = nil
        XCTAssertNil(s.chargeRestoreRecord)
        XCTAssertNil(stored("chargeRestoreRecord"), "clearing must remove the key, not leave an empty value behind")
        XCTAssertNil(Settings(defaults: defaults).chargeRestoreRecord)
    }

    /// A number left under the key is not a record. `string(forKey:)` would hand it back as "90", the controller
    /// would take that for a record it already has, and the real state would never be written down.
    func testARestoreRecordOfTheWrongTypeReadsAsNone() {
        store(90, as: "chargeRestoreRecord")
        XCTAssertNil(Settings(defaults: defaults).chargeRestoreRecord)
        store(Data([1, 2, 3]), as: "chargeRestoreRecord")
        XCTAssertNil(Settings(defaults: defaults).chargeRestoreRecord)
    }

    /// The record is the controller's own bookkeeping: it writes it in the middle of turning Charge Control on and
    /// clears it in the middle of turning it off. A notification there would call the controller back into a
    /// half-finished switch, so a write tells nobody, not even an observer of every key.
    func testWritingTheRestoreRecordNotifiesNobody() {
        let s = Settings(defaults: defaults)
        var fired = 0
        let token = s.observe(Settings.Key.any) { fired += 1 }
        s.chargeRestoreRecord = #"{"mclEnabled":false,"mclLimit":100,"optimizedChargingEnabled":true}"#
        s.chargeRestoreRecord = nil
        XCTAssertEqual(fired, 0)
        _ = token
    }

    // ── What the policy is handed ───────────────────────────────────────────

    /// Each field of the snapshot comes from its own setting. Two arrangements, so that no two switches agree in
    /// both: a snapshot that took `stopWhenSleeping` from the automatic-discharge switch would pass either alone.
    func testSnapshotReadsEachFieldFromItsOwnSetting() {
        let s = Settings(defaults: defaults)
        XCTAssertEqual(s.chargeSettingsSnapshot(),
                       ChargeSettingsSnapshot(limit: 80, sailingEnabled: false, sailingGap: 5,
                                              heatProtectionEnabled: false, maxTemperatureC: 35,
                                              stopWhenSleeping: false, automaticDischarge: false))
        s.chargeLimit = 63
        s.chargeSailingEnabled = true
        s.chargeSailingGap = 9
        s.chargeMaxTemperatureC = 41.5
        s.chargeStopWhenSleeping = true
        XCTAssertEqual(s.chargeSettingsSnapshot(),
                       ChargeSettingsSnapshot(limit: 63, sailingEnabled: true, sailingGap: 9,
                                              heatProtectionEnabled: false, maxTemperatureC: 41.5,
                                              stopWhenSleeping: true, automaticDischarge: false))
        s.chargeSailingEnabled = false
        s.chargeHeatProtectionEnabled = true
        s.chargeStopWhenSleeping = false
        s.chargeAutomaticDischarge = true
        XCTAssertEqual(s.chargeSettingsSnapshot(),
                       ChargeSettingsSnapshot(limit: 63, sailingEnabled: false, sailingGap: 9,
                                              heatProtectionEnabled: true, maxTemperatureC: 41.5,
                                              stopWhenSleeping: false, automaticDischarge: true))
    }

    /// The snapshot is what `ChargePolicy` decides from, and the policy trusts the limit and the maximum temperature
    /// as given. So what is on disk out of range must already be inside the range by the time it is in a snapshot.
    func testSnapshotCarriesClampedValues() {
        store(150, as: "chargeLimit")
        store(0, as: "chargeSailingGap")
        store(10.0, as: "chargeMaxTemperatureC")
        store(true, as: "chargeSailingEnabled")
        store(true, as: "chargeHeatProtectionEnabled")
        XCTAssertEqual(Settings(defaults: defaults).chargeSettingsSnapshot(),
                       ChargeSettingsSnapshot(limit: 100, sailingEnabled: true, sailingGap: 1,
                                              heatProtectionEnabled: true, maxTemperatureC: 25,
                                              stopWhenSleeping: false, automaticDischarge: false))

        store(5, as: "chargeLimit")
        store(99, as: "chargeSailingGap")
        store("hot", as: "chargeMaxTemperatureC")
        XCTAssertEqual(Settings(defaults: defaults).chargeSettingsSnapshot(),
                       ChargeSettingsSnapshot(limit: 20, sailingEnabled: true, sailingGap: 30,
                                              heatProtectionEnabled: true, maxTemperatureC: 35,
                                              stopWhenSleeping: false, automaticDischarge: false))
    }

    /// Why the limit is clamped here and not left to the policy. The policy clamps the limit it gives macOS, but a
    /// discharge drains to the limit as stored, down to a floor of 10. So a stored 5 with Automatic Discharge on
    /// would run a battery at 60% down to 10% on the adapter; read as 20, the drain stops at 20.
    func testAStoredLimitBelowTheRangeCannotDrainThePackBelowIt() {
        store(5, as: "chargeLimit")
        store(true, as: "chargeAutomaticDischarge")
        var memory = ChargeMemory()
        let decision = ChargePolicy.decide(Settings(defaults: defaults).chargeSettingsSnapshot(),
                                           ChargeInputs(percent: 60, onAC: true, temperatureC: 30,
                                                        sleeping: false, topUp: false, manualDischarge: false,
                                                        now: Date(timeIntervalSince1970: 0)),
                                           &memory)
        XCTAssertEqual(decision, ChargeDecision(osLimit: 20, dischargeTo: 20, reason: .discharging))
    }

    /// The same for the temperature, run through the real policy. A stored maximum of 0 is below any temperature a
    /// pack in use can have, so unclamped it would read every pack as hot and Heat Protection would hold the charge
    /// for as long as it was switched on. Read as 25, the lowest a person can choose, a pack at 24 °C is cool and
    /// charges to the limit.
    func testAStoredMaximumOfZeroDoesNotCallEveryPackHot() {
        store(0, as: "chargeMaxTemperatureC")
        store(true, as: "chargeHeatProtectionEnabled")
        var memory = ChargeMemory()
        let decision = ChargePolicy.decide(Settings(defaults: defaults).chargeSettingsSnapshot(),
                                           ChargeInputs(percent: 50, onAC: true, temperatureC: 24,
                                                        sleeping: false, topUp: false, manualDischarge: false,
                                                        now: Date(timeIntervalSince1970: 0)),
                                           &memory)
        XCTAssertEqual(decision, ChargeDecision(osLimit: 80, dischargeTo: nil, reason: .limit))
    }

    /// The opposite failure. No temperature is "at or above" NaN, so a stored NaN that reached the policy would
    /// switch Heat Protection off without saying so. It reads as 35, and a pack at 40 °C is held where it is.
    func testAStoredMaximumThatIsNotANumberStillProtects() {
        store(Double.nan, as: "chargeMaxTemperatureC")
        store(true, as: "chargeHeatProtectionEnabled")
        var memory = ChargeMemory()
        let decision = ChargePolicy.decide(Settings(defaults: defaults).chargeSettingsSnapshot(),
                                           ChargeInputs(percent: 50, onAC: true, temperatureC: 40,
                                                        sleeping: false, topUp: false, manualDischarge: false,
                                                        now: Date(timeIntervalSince1970: 0)),
                                           &memory)
        XCTAssertEqual(decision, ChargeDecision(osLimit: 50, dischargeTo: nil, reason: .heat))
    }
}
