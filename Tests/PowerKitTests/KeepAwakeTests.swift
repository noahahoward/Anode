import XCTest
@testable import PowerKit

/// Keep Awake's rules, played against a fake machine: the sequences that must never leave a laptop unable to sleep.
final class KeepAwakeTests: XCTestCase {

    final class FakeAssertions: SleepAssertions {
        var held = false
        var failNext = false
        func hold(reason: String) -> Bool { if failNext { return false }; held = true; return true }
        func release() { held = false }
    }

    final class FakeLid: ClosedLidSleepControl {
        var disabled = false
        var authorised = true
        var failWrites = false
        func sleepDisabled() -> Bool? { disabled }
        func setSleepDisabled(_ on: Bool) -> Bool {
            if failWrites { return false }
            disabled = on
            return true
        }
        func isAuthorised() -> Bool { authorised }
    }

    private var suite: String!
    private var defaults: UserDefaults!
    private var clock = Date(timeIntervalSince1970: 1_000_000)
    private let assertions = FakeAssertions()
    private let lid = FakeLid()

    override func setUpWithError() throws {
        (defaults, suite) = try TestDefaults.make(owner: "KeepAwake", test: name)
    }
    override func tearDownWithError() throws { TestDefaults.destroy(defaults, suite) }

    private func make() -> KeepAwake {
        KeepAwake(assertions: assertions, lid: lid, defaults: defaults, now: { self.clock })
    }

    // ── Never Sleep ──

    func testNeverSleepHoldsTheAssertionsAndLeavesTheLidAlone() throws {
        let k = make()
        try k.start(.neverSleep)
        XCTAssertTrue(assertions.held)
        XCTAssertFalse(lid.disabled)
        XCTAssertEqual(k.session?.mode, .neverSleep)
        k.stop()
        XCTAssertFalse(assertions.held)
        XCTAssertNil(k.session)
    }

    func testNeverSleepNeedsNoPermission() throws {
        lid.authorised = false
        XCTAssertNoThrow(try make().start(.neverSleep))
    }

    // ── Always Stay Awake ──

    func testAlwaysAwakeDisablesSleepAndStopRestoresIt() throws {
        let k = make()
        try k.start(.alwaysAwake)
        XCTAssertTrue(lid.disabled)
        XCTAssertTrue(assertions.held)
        k.stop()
        XCTAssertFalse(lid.disabled)
        XCTAssertFalse(k.weSetSleepDisabled)
    }

    func testAlwaysAwakeWithoutPermissionChangesNothing() {
        lid.authorised = false
        let k = make()
        XCTAssertThrowsError(try k.start(.alwaysAwake)) { XCTAssertEqual($0 as? KeepAwakeError, .notAuthorised) }
        XCTAssertFalse(assertions.held)
        XCTAssertFalse(lid.disabled)
        XCTAssertNil(k.session)
    }

    func testAFailedWriteDoesNotLeaveTheScreenHalfHeld() {
        lid.failWrites = true
        let k = make()
        XCTAssertThrowsError(try k.start(.alwaysAwake)) { XCTAssertEqual($0 as? KeepAwakeError, .couldNotDisableSleep) }
        XCTAssertFalse(assertions.held)
        XCTAssertNil(k.session)
        XCTAssertFalse(k.weSetSleepDisabled)
    }

    func testSwitchingDownToNeverSleepGivesTheLidBackItsSleep() throws {
        let k = make()
        try k.start(.alwaysAwake)
        try k.start(.neverSleep)
        XCTAssertFalse(lid.disabled)
        XCTAssertTrue(assertions.held)
        XCTAssertEqual(k.session?.mode, .neverSleep)
    }

    // ── Time and battery ──

    func testASessionEndsWhenItsTimeIsUp() throws {
        let k = make()
        try k.start(.neverSleep, for: 900)
        XCTAssertEqual(k.remaining(), 900)
        clock += 899
        k.tick(batteryPercent: 80, onAC: false)
        XCTAssertTrue(k.isActive)
        clock += 1
        k.tick(batteryPercent: 80, onAC: false)
        XCTAssertFalse(k.isActive)
        XCTAssertEqual(k.lastStop, .expired)
        XCTAssertFalse(assertions.held)
    }

    func testAlwaysAwakeStopsOnALowBatteryAndRestoresSleep() throws {
        let k = make()
        try k.start(.alwaysAwake)
        k.tick(batteryPercent: 11, onAC: false)
        XCTAssertTrue(k.isActive)
        k.tick(batteryPercent: 10, onAC: false)
        XCTAssertFalse(k.isActive)
        XCTAssertEqual(k.lastStop, .lowBattery(10))
        XCTAssertFalse(lid.disabled)
    }

    func testALowBatteryOnTheChargerOrWithNeverSleepIsFine() throws {
        let k = make()
        try k.start(.alwaysAwake)
        k.tick(batteryPercent: 3, onAC: true)
        XCTAssertTrue(k.isActive)
        try k.start(.neverSleep)
        k.tick(batteryPercent: 3, onAC: false)
        XCTAssertTrue(k.isActive)
        k.tick(batteryPercent: nil, onAC: true)   // a desktop has no battery
        XCTAssertTrue(k.isActive)
    }

    // ── Crashes ──

    func testALeftOverDisableSleepIsClearedAtTheNextLaunch() throws {
        try make().start(.alwaysAwake)          // …and the app dies here: no stop(), no terminate.
        XCTAssertTrue(lid.disabled)
        let relaunched = make()
        relaunched.reconcileAtLaunch()
        XCTAssertFalse(lid.disabled)
        XCTAssertFalse(relaunched.weSetSleepDisabled)
    }

    func testADisableSleepSomeoneSetByHandIsLeftAlone() {
        lid.disabled = true                      // `sudo pmset -a disablesleep 1`, typed by a person
        let k = make()
        k.reconcileAtLaunch()
        XCTAssertTrue(lid.disabled)
    }

    func testAFailedRestoreIsRememberedAndRetried() throws {
        let k = make()
        try k.start(.alwaysAwake)
        lid.failWrites = true
        k.stop()
        XCTAssertTrue(lid.disabled)
        XCTAssertEqual(k.lastStop, .couldNotRestoreSleep)
        XCTAssertTrue(k.weSetSleepDisabled)
        lid.failWrites = false
        let relaunched = make()
        relaunched.reconcileAtLaunch()
        XCTAssertFalse(lid.disabled)
    }

    // ── pmset and sudoers text ──

    func testSleepDisabledIsReadFromPmsetOutput() {
        XCTAssertEqual(PmsetClosedLidSleep.parseSleepDisabled("System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n sleep 1\n"), true)
        XCTAssertEqual(PmsetClosedLidSleep.parseSleepDisabled(" SleepDisabled\t\t0\n"), false)
        XCTAssertNil(PmsetClosedLidSleep.parseSleepDisabled(" sleep 1\n"))
    }

    func testTheRuleAllowsExactlyTwoCommands() {
        let r = KeepAwakeAuthorisation.rule(user: "noah")
        XCTAssertEqual(r, "noah ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0")
    }

    func testUnsafeUserNamesAreRefusedNotEscaped() {
        for bad in ["", "-x", "a b", "a;b", "a'b", "a\"b", "a$(x)", "a\nb", "ü"] {
            XCTAssertNil(KeepAwakeAuthorisation.installScript(user: bad), bad)
        }
        XCTAssertNotNil(KeepAwakeAuthorisation.installScript(user: "noah.howard_1"))
    }

    func testTheInstallScriptHasNoDoubleQuotesAndValidatesBeforeInstalling() throws {
        let s = try XCTUnwrap(KeepAwakeAuthorisation.installScript(user: "noah"))
        XCTAssertFalse(s.contains("\""))
        let visudo = try XCTUnwrap(s.range(of: "visudo -cf"))
        let install = try XCTUnwrap(s.range(of: "install -m 0440"))
        XCTAssertLessThan(visudo.lowerBound, install.lowerBound)
        XCTAssertTrue(s.contains("&&"))
    }

    func testTheGeneratedRulePassesVisudo() throws {
        // visudo -c on a throwaway file: the same check the installer runs as root, here without installing anything.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("anode-rule-\(UUID().uuidString)")
        try (KeepAwakeAuthorisation.rule(user: NSUserName()) + "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let r = PmsetClosedLidSleep.run("/usr/sbin/visudo", ["-cf", url.path])
        // visudo refuses a file that is not mode 0440 root-owned only with -s strictness; plain -c checks syntax.
        XCTAssertEqual(r?.status, 0, r?.output ?? "visudo did not run")
    }
}
