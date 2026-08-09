import XCTest
@testable import PowerKit

/// The three switches that decide what BetterStats is when it comes up: a
/// windowed app, a menu bar tool, or a recorder.
///
/// Booleans are where a defaults bug hides best. `bool(forKey:)` returns false
/// for "absent", which is indistinguishable from a stored false — so a setting
/// that defaults to TRUE reads as off on a machine that has never touched it,
/// and battery logging would simply never happen on a fresh install. Every
/// default here is asserted against a suite that has never been written.
final class StartupSettingsTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        // A throwaway suite: these tests write settings, and the user's real
        // preferences are not a fixture.
        suiteName = "com.betterstats.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // ── Defaults ────────────────────────────────────────────────────────────

    /// A machine that has never been configured must behave exactly as every
    /// build before these settings existed: window at launch, widgets up,
    /// history recording.
    func testUntouchedDefaultsPreserveTodaysBehaviour() {
        let s = Settings(defaults: defaults)
        XCTAssertFalse(s.startInMenuBarOnly,
                       "a first launch must show a window, or it reads as a failed launch")
        XCTAssertTrue(s.batteryLogging,
                      "history off by default would silently empty the 10 hr power column")
        XCTAssertTrue(s.menuBarWidgetsEnabled,
                      "widgets are the app's front door once the window is closed")
    }

    /// The true-by-default pair is the pair that `bool(forKey:)` gets wrong.
    /// Storing false must actually read back as false rather than being taken for
    /// "absent, so use the default".
    func testAStoredFalseIsNotMistakenForAnAbsentValue() {
        let s = Settings(defaults: defaults)
        s.batteryLogging = false
        s.menuBarWidgetsEnabled = false
        XCTAssertFalse(Settings(defaults: defaults).batteryLogging)
        XCTAssertFalse(Settings(defaults: defaults).menuBarWidgetsEnabled)
    }

    // ── Persistence ─────────────────────────────────────────────────────────

    /// Written by one instance, read by another on the same suite — the CLI and
    /// the app are separate processes sharing this file, so a setting held only
    /// in memory would be a setting the sampler never sees.
    func testSettingsSurviveIntoAnotherInstance() {
        let writer = Settings(defaults: defaults)
        writer.startInMenuBarOnly = true
        writer.batteryLogging = false
        writer.menuBarWidgetsEnabled = false

        let reader = Settings(defaults: defaults)
        XCTAssertTrue(reader.startInMenuBarOnly)
        XCTAssertFalse(reader.batteryLogging)
        XCTAssertFalse(reader.menuBarWidgetsEnabled)
    }

    /// The storage keys are a contract with `defaults write`, which the file's own
    /// design notes call out as one of the three directions values arrive from.
    /// Pinned here so a rename cannot silently orphan a user's configuration.
    func testStorageKeysCarryTheBetterstatsPrefix() {
        let s = Settings(defaults: defaults)
        s.startInMenuBarOnly = true
        s.batteryLogging = false
        s.menuBarWidgetsEnabled = false

        XCTAssertEqual(defaults.object(forKey: "betterstats.startInMenuBarOnly") as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "betterstats.batteryLogging") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "betterstats.menuBarWidgetsEnabled") as? Bool, false)
    }

    /// Setting a value that happens to equal the default must still be RECORDED,
    /// so "never chosen" and "chosen, and it matches" are different states on
    /// disk. Otherwise a later change to a default silently rewrites a decision
    /// the user already made.
    func testWritingTheDefaultValueStillPersistsIt() {
        let s = Settings(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "betterstats.batteryLogging"))
        s.batteryLogging = true   // already the default
        XCTAssertEqual(defaults.object(forKey: "betterstats.batteryLogging") as? Bool, true)
    }

    // ── Observation ─────────────────────────────────────────────────────────

    /// Every one of these changes has to take effect without a relaunch: the
    /// sampler re-reads logging each tick, the widget controller and the
    /// activation policy are driven from the notification.
    func testChangingEachSettingNotifiesItsOwnKey() {
        let s = Settings(defaults: defaults)
        var fired: [String] = []
        let tokens = [
            s.observe(Settings.Key.startInMenuBarOnly) { fired.append("start") },
            s.observe(Settings.Key.batteryLogging) { fired.append("logging") },
            s.observe(Settings.Key.menuBarWidgetsEnabled) { fired.append("widgets") },
        ]

        s.startInMenuBarOnly = true
        s.batteryLogging = false
        s.menuBarWidgetsEnabled = false

        XCTAssertEqual(fired, ["start", "logging", "widgets"])
        XCTAssertEqual(tokens.count, 3)   // retained: a released token unobserves
    }

    /// Re-writing the value already stored must notify nobody. The Preferences
    /// panes refresh from every notification, so a self-triggering write is how a
    /// checkbox starts fighting the user mid-click.
    func testRewritingTheSameValueNotifiesNobody() {
        let s = Settings(defaults: defaults)
        s.menuBarWidgetsEnabled = false
        var count = 0
        let token = s.observe(Settings.Key.menuBarWidgetsEnabled) { count += 1 }

        s.menuBarWidgetsEnabled = false
        XCTAssertEqual(count, 0, "an unchanged write must be silent")

        s.menuBarWidgetsEnabled = true
        XCTAssertEqual(count, 1)
        _ = token
    }

    /// A write through a DIFFERENT Settings instance still reaches this one.
    /// Preferences and the AppDelegate hold their own instances, so without the
    /// reconcile diff a checkbox would change the stored value and the running
    /// app would carry on as before until relaunched.
    func testAWriteThroughAnotherInstanceStillNotifies() {
        let observed = Settings(defaults: defaults)
        let writer = Settings(defaults: defaults)

        var keys: [String] = []
        let token = observed.observe(Settings.Key.any) { keys.append("any") }

        writer.menuBarWidgetsEnabled = false

        XCTAssertFalse(observed.menuBarWidgetsEnabled, "the reader must see the new value")
        XCTAssertFalse(keys.isEmpty, "the other instance's observers were never told")
        _ = token
    }
}
