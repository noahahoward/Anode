import XCTest
@testable import PowerKit

/// Ultra Low Power Mode's settings: whether the feature is on, the groups the owner always wants kept running, and what the
/// mode does besides freezing.
final class UltraLowPowerSettingsTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        (defaults, suiteName) = try TestDefaults.make(owner: "UltraLowPowerSettings", test: name)
    }

    override func tearDownWithError() throws {
        TestDefaults.destroy(defaults, suiteName)
    }

    /// Off, and nothing kept: the mode freezes and dims things, so the owner turns it on and says what to spare.
    func testDefaultsAreOffAndEmpty() {
        let s = Settings(defaults: defaults)
        XCTAssertFalse(s.ultraLowPowerEnabled)
        XCTAssertEqual(s.ultraLowPowerAlwaysKeep, [])
    }

    /// Slower by design, and on: it is what keeps what still runs from burning power in bursts, so the owner turns it off to
    /// keep the apps at full speed.
    func testEfficiencyCoresAreOnByDefaultAndTheSettingRoundTrips() {
        XCTAssertTrue(Settings(defaults: defaults).ultraLowPowerEfficiencyCores)
        Settings(defaults: defaults).ultraLowPowerEfficiencyCores = false
        XCTAssertFalse(Settings(defaults: defaults).ultraLowPowerEfficiencyCores, "a new handle on the same suite")
        XCTAssertFalse(Settings(defaults: defaults).ultraLowPowerEnabled, "a separate key")
        Settings(defaults: defaults).ultraLowPowerEfficiencyCores = true
        XCTAssertTrue(Settings(defaults: defaults).ultraLowPowerEfficiencyCores)
    }

    /// On: with the other apps frozen and hidden, what is lit is the kept app's windows, and a black desktop behind them is
    /// what a darker screen costs the owner least.
    func testTheBlackBackdropIsOnByDefaultAndTheSettingRoundTrips() {
        XCTAssertTrue(Settings(defaults: defaults).ultraLowPowerBlackBackdrop)
        Settings(defaults: defaults).ultraLowPowerBlackBackdrop = false
        XCTAssertFalse(Settings(defaults: defaults).ultraLowPowerBlackBackdrop, "a new handle on the same suite")
        XCTAssertTrue(Settings(defaults: defaults).ultraLowPowerEfficiencyCores, "a separate key")
        Settings(defaults: defaults).ultraLowPowerBlackBackdrop = true
        XCTAssertTrue(Settings(defaults: defaults).ultraLowPowerBlackBackdrop)
    }

    func testAlwaysKeepRoundTrips() {
        let keep = ["com.example.vpn", "job:com.example.database"]
        Settings(defaults: defaults).ultraLowPowerAlwaysKeep = keep
        XCTAssertEqual(Settings(defaults: defaults).ultraLowPowerAlwaysKeep, keep, "a new handle on the same suite")

        Settings(defaults: defaults).ultraLowPowerEnabled = true
        XCTAssertTrue(Settings(defaults: defaults).ultraLowPowerEnabled)
        XCTAssertEqual(Settings(defaults: defaults).ultraLowPowerAlwaysKeep, keep, "the two settings are separate keys")

        // The list is ids to match against, so a blank one and a repeat mean nothing; order is the owner's.
        Settings(defaults: defaults).ultraLowPowerAlwaysKeep = ["b", " a ", "b", "", "  "]
        XCTAssertEqual(Settings(defaults: defaults).ultraLowPowerAlwaysKeep, ["b", "a"])

        Settings(defaults: defaults).ultraLowPowerAlwaysKeep = []
        XCTAssertEqual(Settings(defaults: defaults).ultraLowPowerAlwaysKeep, [])
    }

    /// The preferences file can be hand-edited or written by another build. Whatever is there that is not a JSON list
    /// of strings reads as nothing kept, never as a crash and never as part of a list.
    func testGarbageInTheKeepListReadsAsEmpty() {
        let key = "anode.ultraLowPowerAlwaysKeep"
        defaults.set("not json", forKey: key)
        XCTAssertEqual(Settings(defaults: defaults).ultraLowPowerAlwaysKeep, [])

        defaults.set(#"{"id":"com.example.vpn"}"#, forKey: key)
        XCTAssertEqual(Settings(defaults: defaults).ultraLowPowerAlwaysKeep, [], "JSON, but not a list")
        defaults.set("[1, 2]", forKey: key)
        XCTAssertEqual(Settings(defaults: defaults).ultraLowPowerAlwaysKeep, [], "a list, but not of strings")
        defaults.set(["com.example.vpn"], forKey: key)
        XCTAssertEqual(Settings(defaults: defaults).ultraLowPowerAlwaysKeep, [], "a plist array is not the JSON text")
        defaults.set(5, forKey: key)
        XCTAssertEqual(Settings(defaults: defaults).ultraLowPowerAlwaysKeep, [], "a number")

        // And a good write puts it right.
        Settings(defaults: defaults).ultraLowPowerAlwaysKeep = ["com.example.vpn"]
        XCTAssertEqual(Settings(defaults: defaults).ultraLowPowerAlwaysKeep, ["com.example.vpn"])
    }

    func testObserversFireForEachKey() {
        let s = Settings(defaults: defaults)
        var enabled = 0, keep = 0, cores = 0, backdrop = 0
        let t1 = s.observe(Settings.Key.ultraLowPowerEnabled) { enabled += 1 }
        let t2 = s.observe(Settings.Key.ultraLowPowerAlwaysKeep) { keep += 1 }
        let t3 = s.observe(Settings.Key.ultraLowPowerEfficiencyCores) { cores += 1 }
        let t4 = s.observe(Settings.Key.ultraLowPowerBlackBackdrop) { backdrop += 1 }

        // Through the handle itself: once per change, none for a write that changes nothing.
        s.ultraLowPowerEnabled = true
        s.ultraLowPowerEnabled = true
        s.ultraLowPowerAlwaysKeep = ["com.example.vpn"]
        s.ultraLowPowerAlwaysKeep = ["com.example.vpn"]
        s.ultraLowPowerEfficiencyCores = false
        s.ultraLowPowerEfficiencyCores = false
        s.ultraLowPowerBlackBackdrop = false
        s.ultraLowPowerBlackBackdrop = false
        XCTAssertEqual([enabled, keep, cores, backdrop], [1, 1, 1, 1])

        // Through another handle on the same suite, which is how the Beta Features window reaches a feature that
        // watches its own: `reconcile()` carries it across, and a key left out of it fails without a sound.
        let other = Settings(defaults: defaults)
        other.ultraLowPowerEnabled = false
        other.ultraLowPowerAlwaysKeep = ["com.example.vpn", "job:com.example.database"]
        other.ultraLowPowerEfficiencyCores = true
        other.ultraLowPowerBlackBackdrop = true
        XCTAssertEqual([enabled, keep, cores, backdrop], [2, 2, 2, 2])
        _ = (t1, t2, t3, t4)
    }
}
