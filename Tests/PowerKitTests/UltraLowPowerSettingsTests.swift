import XCTest
@testable import PowerKit

/// Ultra Low Power Mode's two settings: whether the feature is on, and the groups the owner always wants kept running.
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
        var enabled = 0, keep = 0
        let t1 = s.observe(Settings.Key.ultraLowPowerEnabled) { enabled += 1 }
        let t2 = s.observe(Settings.Key.ultraLowPowerAlwaysKeep) { keep += 1 }

        // Through the handle itself: once per change, none for a write that changes nothing.
        s.ultraLowPowerEnabled = true
        s.ultraLowPowerEnabled = true
        s.ultraLowPowerAlwaysKeep = ["com.example.vpn"]
        s.ultraLowPowerAlwaysKeep = ["com.example.vpn"]
        XCTAssertEqual([enabled, keep], [1, 1])

        // Through another handle on the same suite, which is how the Beta Features window reaches a feature that
        // watches its own: `reconcile()` carries it across, and a key left out of it fails without a sound.
        let other = Settings(defaults: defaults)
        other.ultraLowPowerEnabled = false
        other.ultraLowPowerAlwaysKeep = ["com.example.vpn", "job:com.example.database"]
        XCTAssertEqual([enabled, keep], [2, 2])
        _ = (t1, t2)
    }
}
