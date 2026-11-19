import XCTest
@testable import PowerKit

/// Clipboard History's settings: the switch, the pause, how long and how many, whether pictures are kept, and the apps whose
/// copies are never recorded.
///
/// The two numbers get the most tests because a number that is out of range, of the wrong type or not a number has to be
/// stopped here whichever way it arrived: from the screen, from `defaults write`, or from a file another build left behind.
final class ClipboardSettingsTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        (defaults, suiteName) = try TestDefaults.make(owner: "ClipboardSettings", test: name)
    }

    override func tearDownWithError() throws {
        TestDefaults.destroy(defaults, suiteName)
    }

    /// What is on disk for a setting, read around `Settings`. The name is spelled out, never taken from `Settings.Key`: these
    /// strings are the storage format, and a rename would orphan what someone had set.
    private func stored(_ name: String) -> Any? { defaults.object(forKey: "anode." + name) }

    /// Put a value on disk the way `defaults write` or another build would: with no validation at all.
    private func store(_ value: Any, as name: String) { defaults.set(value, forKey: "anode." + name) }

    /// One observer for each of the six keys on `s`; each reports its short name when it fires. Keep the tokens: a released
    /// token unobserves.
    private func observeEveryClipboardKey(of s: Settings, _ report: @escaping (String) -> Void) -> [AnyObject] {
        [(Settings.Key.clipboardHistoryEnabled, "enabled"),
         (Settings.Key.clipboardHistoryPaused, "paused"),
         (Settings.Key.clipboardHistoryKeepMinutes, "keepMinutes"),
         (Settings.Key.clipboardHistoryMaxEntries, "maxEntries"),
         (Settings.Key.clipboardHistoryKeepImages, "keepImages"),
         (Settings.Key.clipboardHistoryIgnoredApps, "ignoredApps")]
            .map { key, name in s.observe(key) { report(name) } }
    }

    // ── Defaults ────────────────────────────────────────────────────────────

    /// A Mac that has never seen Clipboard History: off (it keeps what is copied, on disk), not paused, a day, five hundred,
    /// pictures kept, and no app left out beyond the password managers that always are.
    func testDefaults() {
        let s = Settings(defaults: defaults)
        XCTAssertFalse(s.clipboardHistoryEnabled, "off until asked for")
        XCTAssertFalse(s.clipboardHistoryPaused)
        XCTAssertEqual(s.clipboardHistoryKeepMinutes, 1440)
        XCTAssertEqual(s.clipboardHistoryMaxEntries, 500)
        XCTAssertTrue(s.clipboardHistoryKeepImages)
        XCTAssertEqual(s.clipboardHistoryIgnoredApps, [])
    }

    /// The ranges are public so the controls stay in step with what is accepted.
    func testTheRangesAreTheOnesTheScreenOffers() {
        XCTAssertEqual(Settings.clipboardHistoryKeepMinutesRange, 0...525_600, "0 is for ever, and the most is a year")
        XCTAssertEqual(Settings.clipboardHistoryMaxEntriesRange, 10...5000)
    }

    // ── Each setting, and only that setting ─────────────────────────────────

    /// Each one written through one handle and read through another on the same store, as a new launch reads it.
    func testEverySettingRoundTripsThroughANewHandle() {
        let s = Settings(defaults: defaults)
        s.clipboardHistoryEnabled = true
        s.clipboardHistoryPaused = true
        s.clipboardHistoryKeepMinutes = 60
        s.clipboardHistoryMaxEntries = 120
        s.clipboardHistoryKeepImages = false
        s.clipboardHistoryIgnoredApps = ["com.example.Vault", "com.example.Banking"]

        let again = Settings(defaults: defaults)
        XCTAssertTrue(again.clipboardHistoryEnabled)
        XCTAssertTrue(again.clipboardHistoryPaused)
        XCTAssertEqual(again.clipboardHistoryKeepMinutes, 60)
        XCTAssertEqual(again.clipboardHistoryMaxEntries, 120)
        XCTAssertFalse(again.clipboardHistoryKeepImages)
        XCTAssertEqual(again.clipboardHistoryIgnoredApps, ["com.example.Vault", "com.example.Banking"], "in the order the person gave")
    }

    /// Six settings, six keys: each is moved off its default alone and must be the only one that reads differently. Two of
    /// them pasted onto one key would pass every test that only reads back the value it just wrote.
    func testEachSettingIsStoredOnItsOwnKey() {
        let changes: [(name: String, key: String, apply: (Settings) -> Void)] = [
            ("enabled", "clipboardHistoryEnabled", { $0.clipboardHistoryEnabled = true }),
            ("paused", "clipboardHistoryPaused", { $0.clipboardHistoryPaused = true }),
            ("keepMinutes", "clipboardHistoryKeepMinutes", { $0.clipboardHistoryKeepMinutes = 61 }),
            ("maxEntries", "clipboardHistoryMaxEntries", { $0.clipboardHistoryMaxEntries = 123 }),
            ("keepImages", "clipboardHistoryKeepImages", { $0.clipboardHistoryKeepImages = false }),
            ("ignoredApps", "clipboardHistoryIgnoredApps", { $0.clipboardHistoryIgnoredApps = ["com.example.Vault"] }),
        ]
        for change in changes {
            let fresh = TestDefaults.throwaway("ClipboardSettingsOwnKey")
            change.apply(Settings(defaults: fresh))
            XCTAssertNotNil(fresh.object(forKey: "anode." + change.key), "\(change.name) is stored under anode.\(change.key)")
            let read = Settings(defaults: fresh)
            let now = [read.clipboardHistoryEnabled == false, read.clipboardHistoryPaused == false,
                       read.clipboardHistoryKeepMinutes == 1440, read.clipboardHistoryMaxEntries == 500,
                       read.clipboardHistoryKeepImages == true, read.clipboardHistoryIgnoredApps.isEmpty]
            let names = ["enabled", "paused", "keepMinutes", "maxEntries", "keepImages", "ignoredApps"]
            for (n, atDefault) in now.enumerated() {
                XCTAssertEqual(atDefault, names[n] != change.name, "\(names[n]) after changing only \(change.name)")
            }
        }
    }

    // ── The two numbers ─────────────────────────────────────────────────────

    /// How long: a minute count from 0 (for ever) to a year; below or above is the nearest end. What is stored is checked as
    /// well as what reads back, so a setter that stored the raw value would not pass.
    func testKeepMinutesClamps() {
        let s = Settings(defaults: defaults)
        s.clipboardHistoryKeepMinutes = -5
        XCTAssertEqual(s.clipboardHistoryKeepMinutes, 0)
        XCTAssertEqual((stored("clipboardHistoryKeepMinutes") as? NSNumber)?.intValue, 0)
        s.clipboardHistoryKeepMinutes = 600_000
        XCTAssertEqual(s.clipboardHistoryKeepMinutes, 525_600)
        XCTAssertEqual((stored("clipboardHistoryKeepMinutes") as? NSNumber)?.intValue, 525_600)
        s.clipboardHistoryKeepMinutes = 525_600
        XCTAssertEqual(s.clipboardHistoryKeepMinutes, 525_600, "a year exactly")
        s.clipboardHistoryKeepMinutes = 0
        XCTAssertEqual(s.clipboardHistoryKeepMinutes, 0, "0 is for ever and is a choice, not a clamp")
        s.clipboardHistoryKeepMinutes = 90
        XCTAssertEqual(s.clipboardHistoryKeepMinutes, 90)
        s.clipboardHistoryKeepMinutes = Int.min
        XCTAssertEqual(s.clipboardHistoryKeepMinutes, 0)
        s.clipboardHistoryKeepMinutes = Int.max
        XCTAssertEqual(s.clipboardHistoryKeepMinutes, 525_600)
    }

    /// How many: from ten to five thousand.
    func testMaxEntriesClamps() {
        let s = Settings(defaults: defaults)
        s.clipboardHistoryMaxEntries = 0
        XCTAssertEqual(s.clipboardHistoryMaxEntries, 10)
        XCTAssertEqual((stored("clipboardHistoryMaxEntries") as? NSNumber)?.intValue, 10)
        s.clipboardHistoryMaxEntries = 9
        XCTAssertEqual(s.clipboardHistoryMaxEntries, 10)
        s.clipboardHistoryMaxEntries = 10
        XCTAssertEqual(s.clipboardHistoryMaxEntries, 10)
        s.clipboardHistoryMaxEntries = 7000
        XCTAssertEqual(s.clipboardHistoryMaxEntries, 5000)
        XCTAssertEqual((stored("clipboardHistoryMaxEntries") as? NSNumber)?.intValue, 5000)
        s.clipboardHistoryMaxEntries = 5001
        XCTAssertEqual(s.clipboardHistoryMaxEntries, 5000)
        s.clipboardHistoryMaxEntries = 250
        XCTAssertEqual(s.clipboardHistoryMaxEntries, 250)
        s.clipboardHistoryMaxEntries = Int.min
        XCTAssertEqual(s.clipboardHistoryMaxEntries, 10)
        s.clipboardHistoryMaxEntries = Int.max
        XCTAssertEqual(s.clipboardHistoryMaxEntries, 5000)
    }

    /// Values that reached the file without passing through a setter. Out of range reads as the nearest end; anything that is
    /// not a number reads as the default, a Boolean (which bridges to a number) and the text "60" (which `defaults write` stores
    /// when it is not told `-int`) included.
    ///
    /// Each is stored on top of a good value that no case expects (321, 77): a case that never reached the file would then
    /// read as that value and fail, where over an empty key it would read as the default and pass.
    func testCorruptStoredNumbersReadAsTheDefaultOrAreClamped() {
        let minutes: [(stored: Any, want: Int)] = [
            (60.4, 60), (60.6, 61), (0, 0), (-3, 0), (9_999_999, 525_600), (Int.max, 525_600), (Int.min, 0), (1e300, 525_600),
            (-1e300, 0),
            ("60", 1440), ("", 1440), (Data([6, 0]), 1440), ([60], 1440), (["minutes": 60], 1440),
            (Date(timeIntervalSince1970: 60), 1440), (true, 1440), (false, 1440),
            (Double.nan, 1440), (Double.infinity, 1440), (-Double.infinity, 1440),
        ]
        for (raw, want) in minutes {
            store(321, as: "clipboardHistoryKeepMinutes")
            store(raw, as: "clipboardHistoryKeepMinutes")
            XCTAssertEqual(Settings(defaults: defaults).clipboardHistoryKeepMinutes, want, "keep minutes stored as \(raw)")
        }

        let counts: [(stored: Any, want: Int)] = [
            (5, 10), (0, 10), (-40, 10), (9, 10), (10, 10), (5000, 5000), (5001, 5000), (Int.max, 5000), (Int.min, 10),
            (99.6, 100), (1e300, 5000), (-1e300, 10),
            ("100", 500), ("", 500), (Data([1, 0, 0]), 500), ([100], 500), (["entries": 100], 500),
            (Date(timeIntervalSince1970: 100), 500), (true, 500), (false, 500),
            (Double.nan, 500), (Double.infinity, 500), (-Double.infinity, 500),
        ]
        for (raw, want) in counts {
            store(77, as: "clipboardHistoryMaxEntries")
            store(raw, as: "clipboardHistoryMaxEntries")
            XCTAssertEqual(Settings(defaults: defaults).clipboardHistoryMaxEntries, want, "max entries stored as \(raw)")
        }
    }

    // ── The switches ────────────────────────────────────────────────────────

    /// Something that is not a Boolean reads as the default of the switch it is on, so a hand-edited file cannot turn the
    /// history on, or turn the picture switch off, by being strange.
    func testAStoredValueThatIsNotABooleanReadsAsTheDefault() {
        for raw in ["yes", "no", "false", Data([1]), [true]] as [Any] {
            store(raw, as: "clipboardHistoryEnabled")
            store(raw, as: "clipboardHistoryPaused")
            store(raw, as: "clipboardHistoryKeepImages")
            let s = Settings(defaults: defaults)
            XCTAssertFalse(s.clipboardHistoryEnabled, "enabled stored as \(raw)")
            XCTAssertFalse(s.clipboardHistoryPaused, "paused stored as \(raw)")
            XCTAssertTrue(s.clipboardHistoryKeepImages, "keep images stored as \(raw)")
        }
    }

    // ── The apps left out ───────────────────────────────────────────────────

    /// The list is ids to match against, so a blank one and a repeat mean nothing, and spaces round an id are not part of it;
    /// the order is the person's, and an id of an app that is not installed is kept.
    func testTheIgnoredAppsAreCleanedLikeTheOtherIDLists() {
        Settings(defaults: defaults).clipboardHistoryIgnoredApps = ["b", " a ", "b", "", "  ", "\ncom.example.Vault\t", "com.example.NotInstalled"]
        XCTAssertEqual(Settings(defaults: defaults).clipboardHistoryIgnoredApps, ["b", "a", "com.example.Vault", "com.example.NotInstalled"])
        XCTAssertEqual(defaults.stringArray(forKey: "anode.clipboardHistoryIgnoredApps"),
                       ["b", "a", "com.example.Vault", "com.example.NotInstalled"], "what is on disk is the clean list")

        Settings(defaults: defaults).clipboardHistoryIgnoredApps = []
        XCTAssertEqual(Settings(defaults: defaults).clipboardHistoryIgnoredApps, [])
    }

    /// A list that was written dirty (by hand, or by another build) reads clean.
    func testADirtyStoredListReadsClean() {
        store([" a ", "a", "", "b"], as: "clipboardHistoryIgnoredApps")
        XCTAssertEqual(Settings(defaults: defaults).clipboardHistoryIgnoredApps, ["a", "b"])
    }

    /// Anything stored there that is not a list of strings is no list: nothing is left out beyond the managers.
    func testAStoredIgnoredListThatIsNotAListOfStringsReadsAsEmpty() {
        for raw in ["com.example.Vault", 5, true, ["com.example.Vault": 1], [1, 2], Data([1])] as [Any] {
            store(raw, as: "clipboardHistoryIgnoredApps")
            XCTAssertEqual(Settings(defaults: defaults).clipboardHistoryIgnoredApps, [], "stored as \(raw)")
        }
        // And a good write puts it right.
        Settings(defaults: defaults).clipboardHistoryIgnoredApps = ["com.example.Vault"]
        XCTAssertEqual(Settings(defaults: defaults).clipboardHistoryIgnoredApps, ["com.example.Vault"])
    }

    /// The list tells its observers when it changes, once; a write that changes nothing (the same list, or a dirty copy of it)
    /// tells nobody.
    func testTheIgnoredAppsListNotifiesItsObserversWhenItChanges() {
        let s = Settings(defaults: defaults)
        var heard = 0
        let token = s.observe(Settings.Key.clipboardHistoryIgnoredApps) { heard += 1 }
        s.clipboardHistoryIgnoredApps = ["com.example.Vault"]
        XCTAssertEqual(heard, 1)
        s.clipboardHistoryIgnoredApps = ["com.example.Vault"]
        XCTAssertEqual(heard, 1, "the same list")
        s.clipboardHistoryIgnoredApps = [" com.example.Vault ", "com.example.Vault", ""]
        XCTAssertEqual(heard, 1, "the same list once it is cleaned")
        s.clipboardHistoryIgnoredApps = ["com.example.Vault", "com.example.Banking"]
        XCTAssertEqual(heard, 2)
        s.clipboardHistoryIgnoredApps = []
        XCTAssertEqual(heard, 3)
        _ = token
    }

    // ── Observers ───────────────────────────────────────────────────────────

    /// Every one of the six keys tells its own observer once when it changes, tells no other, and tells nobody when it is set
    /// to what it already is.
    func testEveryKeyNotifiesItsOwnObserverOnceAndNotForTheSameValue() {
        let s = Settings(defaults: defaults)
        var counts: [String: Int] = [:]
        let tokens = observeEveryClipboardKey(of: s) { counts[$0, default: 0] += 1 }
        let changes: [(name: String, change: () -> Void)] = [
            ("enabled", { s.clipboardHistoryEnabled = true }),
            ("paused", { s.clipboardHistoryPaused = true }),
            ("keepMinutes", { s.clipboardHistoryKeepMinutes = 60 }),
            ("maxEntries", { s.clipboardHistoryMaxEntries = 100 }),
            ("keepImages", { s.clipboardHistoryKeepImages = false }),
            ("ignoredApps", { s.clipboardHistoryIgnoredApps = ["com.example.Vault"] }),
        ]
        for (name, change) in changes {
            var expected = counts
            expected[name, default: 0] += 1
            change()
            XCTAssertEqual(counts, expected, "\(name) tells its own observer once, and no other")
            change()
            XCTAssertEqual(counts, expected, "\(name) set to what it already is tells nobody")
        }
        XCTAssertEqual(counts.count, 6)
        _ = tokens
    }

    /// A change made through ANOTHER handle on the same store (the Beta Features window has one of its own) reaches the
    /// observers of the first, once for each key. `reconcile()` carries it across, and a key left out of it fails silently.
    func testAChangeThroughAnotherHandleReachesEveryKeysObserver() {
        let s = Settings(defaults: defaults)
        var counts: [String: Int] = [:]
        let tokens = observeEveryClipboardKey(of: s) { counts[$0, default: 0] += 1 }

        let other = Settings(defaults: defaults)
        other.clipboardHistoryEnabled = true
        other.clipboardHistoryPaused = true
        other.clipboardHistoryKeepMinutes = 60
        other.clipboardHistoryMaxEntries = 100
        other.clipboardHistoryKeepImages = false
        other.clipboardHistoryIgnoredApps = ["com.example.Vault"]
        XCTAssertEqual(counts, ["enabled": 1, "paused": 1, "keepMinutes": 1, "maxEntries": 1, "keepImages": 1, "ignoredApps": 1])
        XCTAssertTrue(s.clipboardHistoryEnabled, "and the first handle reads what the other wrote")
        XCTAssertEqual(s.clipboardHistoryIgnoredApps, ["com.example.Vault"])
        _ = tokens
    }

    /// Choosing what is already the default is written down (so "never chose" and "chose the default" differ on disk) and
    /// tells nobody, since nothing changed.
    func testChoosingTheDefaultIsRecordedAndTellsNobody() {
        let s = Settings(defaults: defaults)
        var counts: [String: Int] = [:]
        let tokens = observeEveryClipboardKey(of: s) { counts[$0, default: 0] += 1 }
        XCTAssertNil(stored("clipboardHistoryKeepMinutes"))
        s.clipboardHistoryEnabled = false
        s.clipboardHistoryPaused = false
        s.clipboardHistoryKeepMinutes = 1440
        s.clipboardHistoryMaxEntries = 500
        s.clipboardHistoryKeepImages = true
        XCTAssertTrue(counts.isEmpty, "\(counts)")
        XCTAssertEqual((stored("clipboardHistoryKeepMinutes") as? NSNumber)?.intValue, 1440)
        XCTAssertEqual((stored("clipboardHistoryMaxEntries") as? NSNumber)?.intValue, 500)
        XCTAssertNotNil(stored("clipboardHistoryEnabled"))
        _ = tokens
    }

    /// A write that clamps to what is already stored changes nothing, so it tells nobody.
    func testAWriteThatClampsToTheValueAlreadyStoredTellsNobody() {
        let s = Settings(defaults: defaults)
        var heard = 0
        let token = s.observe(Settings.Key.clipboardHistoryKeepMinutes) { heard += 1 }
        s.clipboardHistoryKeepMinutes = 600_000
        XCTAssertEqual(heard, 1)
        s.clipboardHistoryKeepMinutes = 900_000
        XCTAssertEqual(heard, 1, "both are a year")
        s.clipboardHistoryKeepMinutes = 525_600
        XCTAssertEqual(heard, 1)
        _ = token
    }
}
