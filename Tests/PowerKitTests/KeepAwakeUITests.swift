import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// The Keep Awake controls drive the controller the way a click would: choosing Always Stay Awake in the Beta
/// Features pop-up must make Always Stay Awake what the next Turn On starts.
final class KeepAwakeUITests: XCTestCase {

    private func rig() throws -> (KeepAwakeController, KeepAwakeFeature, KeepAwakeTests.FakeLid, KeepAwakeTests.FakeAssertions, UserDefaults, String) {
        let (defaults, suite) = try TestDefaults.make(owner: "KeepAwakeUI", test: name)
        let settings = Settings(defaults: defaults)
        let lid = KeepAwakeTests.FakeLid(), assertions = KeepAwakeTests.FakeAssertions()
        let core = KeepAwake(assertions: assertions, lid: lid, defaults: defaults)
        let dimmer = LidDimmer(lid: LidDimmerTests.FakeLidState(), backlight: LidDimmerTests.FakeBacklight(), defaults: defaults)
        let c = KeepAwakeController(settings: settings, defaults: defaults, core: core, dimmer: dimmer)
        c.log = { _ in }
        KeepAwakeController.current = c
        let f = KeepAwakeFeature(settings: settings, isAuthorised: { lid.authorised })
        settings.keepAwakeEnabled = true
        _ = f.makeView()
        return (c, f, lid, assertions, defaults, suite)
    }

    func testChoosingAlwaysStayAwakeInThePopUpThenTurnOnStartsIt() throws {
        let (c, f, lid, _, defaults, suite) = try rig()
        defer { TestDefaults.destroy(defaults, suite); KeepAwakeController.current = nil }
        XCTAssertEqual(f.modePopUp.numberOfItems, 2)
        // As a click on the second item does.
        f.modePopUp.menu?.performActionForItem(at: 1)
        XCTAssertEqual(c.mode, .alwaysAwake, "the pop-up choice must reach the controller")
        f.switchButton.performClick(nil)
        XCTAssertEqual(c.core.session?.mode, .alwaysAwake)
        XCTAssertTrue(lid.disabled)
        XCTAssertEqual(KeepAwakeController.icon(for: c.core.session?.mode)?.accessibilityDescription, "Keep Awake")
        f.switchButton.performClick(nil)
        XCTAssertFalse(c.core.isActive)
        XCTAssertFalse(lid.disabled)
    }

    func testWithoutPermissionTurnOnDoesNotStartAlwaysAndDoesNotChangeTheMode() throws {
        let (c, _, lid, _, defaults, suite) = try rig()
        defer { TestDefaults.destroy(defaults, suite); KeepAwakeController.current = nil }
        lid.authorised = false
        XCTAssertThrowsError(try c.core.start(.alwaysAwake))
        XCTAssertFalse(c.core.isActive)
    }
}

/// The click cycle and the relaunch handoff.
final class KeepAwakeCycleTests: XCTestCase {

    private func rig(authorised: Bool = true) throws -> (KeepAwakeController, KeepAwakeTests.FakeLid, UserDefaults, Settings, String) {
        let (defaults, suite) = try TestDefaults.make(owner: "KeepAwakeCycle", test: name)
        let settings = Settings(defaults: defaults)
        settings.keepAwakeEnabled = true
        let lid = KeepAwakeTests.FakeLid(); lid.authorised = authorised
        let core = KeepAwake(assertions: KeepAwakeTests.FakeAssertions(), lid: lid, defaults: defaults)
        let dimmer = LidDimmer(lid: LidDimmerTests.FakeLidState(), backlight: LidDimmerTests.FakeBacklight(), defaults: defaults)
        let c = KeepAwakeController(settings: settings, defaults: defaults, core: core, dimmer: dimmer)
        c.log = { _ in }
        c.confirmPermission = { false }   // never a real dialog in a test
        return (c, lid, defaults, settings, suite)
    }

    func testEachClickMovesToTheNextOfThreeStates() throws {
        let (c, lid, defaults, _, suite) = try rig()
        defer { TestDefaults.destroy(defaults, suite) }
        XCTAssertNil(c.core.session)
        c.cycle(); XCTAssertEqual(c.core.session?.mode, .neverSleep)
        c.cycle(); XCTAssertEqual(c.core.session?.mode, .alwaysAwake)
        XCTAssertTrue(lid.disabled)
        c.cycle(); XCTAssertNil(c.core.session)
        XCTAssertFalse(lid.disabled)
        c.cycle(); XCTAssertEqual(c.core.session?.mode, .neverSleep)   // and round again
        c.core.stop()
    }

    func testAnUnavailableAlwaysStayAwakeLandsOnOffNotBackOnNeverSleep() throws {
        let (c, lid, defaults, _, suite) = try rig(authorised: false)
        defer { TestDefaults.destroy(defaults, suite) }
        c.cycle(); XCTAssertEqual(c.core.session?.mode, .neverSleep)
        // Always Stay Awake without permission: the owner is asked, says no, and the click lands on off.
        c.cycle()
        XCTAssertNil(c.core.session)
        XCTAssertFalse(lid.disabled)
    }

    func testARelaunchWithAHandoffResumesInsteadOfClearingTheLidSetting() throws {
        let (defaults, suite) = try TestDefaults.make(owner: "KeepAwakeHandoff", test: name)
        defer { TestDefaults.destroy(defaults, suite) }
        let settings = Settings(defaults: defaults); settings.keepAwakeEnabled = true
        let lid = KeepAwakeTests.FakeLid()
        // The previous build set it, and was replaced while it ran.
        try KeepAwake(assertions: KeepAwakeTests.FakeAssertions(), lid: lid, defaults: defaults).start(.alwaysAwake)
        defaults.set(KeepAwakeMode.alwaysAwake.rawValue, forKey: KeepAwakeController.handoffKey)
        let core = KeepAwake(assertions: KeepAwakeTests.FakeAssertions(), lid: lid, defaults: defaults)
        let dimmer = LidDimmer(lid: LidDimmerTests.FakeLidState(), backlight: LidDimmerTests.FakeBacklight(), defaults: defaults)
        let c = KeepAwakeController(settings: settings, defaults: defaults, core: core, dimmer: dimmer)
        c.log = { _ in }
        XCTAssertEqual(c.core.session?.mode, .alwaysAwake)
        XCTAssertTrue(lid.disabled, "never cleared in between")
        XCTAssertNil(defaults.object(forKey: KeepAwakeController.handoffKey), "one-shot")
        c.core.stop()
    }

    func testALaunchWithoutAHandoffStillClearsWhatACrashLeft() throws {
        let (defaults, suite) = try TestDefaults.make(owner: "KeepAwakeNoHandoff", test: name)
        defer { TestDefaults.destroy(defaults, suite) }
        let settings = Settings(defaults: defaults); settings.keepAwakeEnabled = true
        let lid = KeepAwakeTests.FakeLid()
        try KeepAwake(assertions: KeepAwakeTests.FakeAssertions(), lid: lid, defaults: defaults).start(.alwaysAwake)
        let core = KeepAwake(assertions: KeepAwakeTests.FakeAssertions(), lid: lid, defaults: defaults)
        let dimmer = LidDimmer(lid: LidDimmerTests.FakeLidState(), backlight: LidDimmerTests.FakeBacklight(), defaults: defaults)
        _ = KeepAwakeController(settings: settings, defaults: defaults, core: core, dimmer: dimmer)
        XCTAssertFalse(lid.disabled)
    }
}

/// The three Keep Awake icons are drawn, and are template images so the menu bar inks them.
final class KeepAwakeIconTests: XCTestCase {
    func testEveryStateHasAnIcon() {
        for mode in [nil, KeepAwakeMode.neverSleep, .alwaysAwake] {
            let image = KeepAwakeController.icon(for: mode)
            XCTAssertNotNil(image, "\(String(describing: mode))")
            XCTAssertEqual(image?.isTemplate, true)
        }
    }
}
