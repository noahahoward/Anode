import XCTest
@testable import PowerKit

/// Memory Watch's two settings: the switch, and the identity keys the person asked not to be warned about. Both live on a
/// throwaway store; none of this touches the person's own settings.
final class MemoryWatchSettingsTests: XCTestCase {

    /// A feature that reads other processes' memory on every tick and posts notifications is off until asked for, and the
    /// ignore list starts empty. Failing here means a fresh install watches without being asked.
    func testMemoryWatchIsOffByDefaultAndTheIgnoreListStartsEmpty() throws {
        let s = try throwawaySettings(owner: "MemoryWatchDefaults")
        XCTAssertFalse(s.memoryWatchEnabled)
        XCTAssertEqual(s.memoryWatchIgnoredApps, [])
    }

    /// Both settings are remembered by a new handle on the same store, which is what a relaunch is.
    func testBothSettingsSurviveARestart() throws {
        let (defaults, suite) = try TestDefaults.make(owner: "MemoryWatchRoundTrip")
        defer { TestDefaults.destroy(defaults, suite) }
        let s = Settings(defaults: defaults)
        s.memoryWatchEnabled = true
        s.memoryWatchIgnoredApps = ["/Applications/Noisy.app", "/usr/local/bin/node"]
        let again = Settings(defaults: defaults)
        XCTAssertTrue(again.memoryWatchEnabled)
        XCTAssertEqual(again.memoryWatchIgnoredApps, ["/Applications/Noisy.app", "/usr/local/bin/node"])
        again.memoryWatchEnabled = false
        XCTAssertFalse(Settings(defaults: defaults).memoryWatchEnabled)
    }

    /// The ignore list keeps its order, drops blanks and repeats, like the other id lists.
    func testTheIgnoreListIsTidiedLikeTheOtherListsOfIds() throws {
        let s = try throwawaySettings(owner: "MemoryWatchTidy")
        s.memoryWatchIgnoredApps = ["/Applications/B.app", " ", "/Applications/A.app", "/Applications/B.app"]
        XCTAssertEqual(s.memoryWatchIgnoredApps, ["/Applications/B.app", "/Applications/A.app"])
    }

    /// The switch and the list tell the app when they change, and only when they do.
    func testChangesAreObservedOnlyWhenTheyChangeSomething() throws {
        let s = try throwawaySettings(owner: "MemoryWatchObserve")
        var switched = 0, listed = 0
        let t1 = s.observe(Settings.Key.memoryWatchEnabled) { switched += 1 }
        let t2 = s.observe(Settings.Key.memoryWatchIgnoredApps) { listed += 1 }
        s.memoryWatchEnabled = true
        s.memoryWatchEnabled = true
        s.memoryWatchIgnoredApps = ["/Applications/A.app"]
        s.memoryWatchIgnoredApps = ["/Applications/A.app"]
        s.memoryWatchEnabled = false
        XCTAssertEqual(switched, 2)
        XCTAssertEqual(listed, 1)
        withExtendedLifetime((t1, t2)) {}
    }

    /// Storage keys carry the usual "anode." prefix, so the settings cannot collide with another app's.
    func testTheStorageKeysCarryTheAnodePrefix() throws {
        let (defaults, suite) = try TestDefaults.make(owner: "MemoryWatchKeys")
        defer { TestDefaults.destroy(defaults, suite) }
        let s = Settings(defaults: defaults)
        s.memoryWatchEnabled = true
        s.memoryWatchIgnoredApps = ["/Applications/A.app"]
        XCTAssertEqual(defaults.object(forKey: "anode.memoryWatchEnabled") as? Bool, true)
        XCTAssertEqual(defaults.stringArray(forKey: "anode.memoryWatchIgnoredApps"), ["/Applications/A.app"])
    }

    /// The high-memory warning is off until asked for, remembered by a new handle on the same store, stored under the usual
    /// prefix, and observed only when it changes.
    func testThePressureWarningIsOffByDefaultAndRoundTrips() throws {
        let (defaults, suite) = try TestDefaults.make(owner: "MemoryWatchPressure")
        defer { TestDefaults.destroy(defaults, suite) }
        let s = Settings(defaults: defaults)
        XCTAssertFalse(s.memoryWatchPressureWarning)
        var changed = 0
        let token = s.observe(Settings.Key.memoryWatchPressureWarning) { changed += 1 }
        s.memoryWatchPressureWarning = true
        s.memoryWatchPressureWarning = true
        XCTAssertTrue(Settings(defaults: defaults).memoryWatchPressureWarning)
        XCTAssertEqual(defaults.object(forKey: "anode.memoryWatchPressureWarning") as? Bool, true)
        s.memoryWatchPressureWarning = false
        XCTAssertFalse(Settings(defaults: defaults).memoryWatchPressureWarning)
        XCTAssertEqual(changed, 2)
        XCTAssertFalse(s.memoryWatchEnabled, "it does not turn Memory Watch itself on")
        withExtendedLifetime(token) {}
    }
}
