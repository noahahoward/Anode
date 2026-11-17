import XCTest
@testable import PowerKit
@testable import AnodeApp

/// The Sound and Battery menus follow Reduce Transparency (no glass, a solid panel), as macOS's own panels do.
final class MenusFollowAccessibilityTests: XCTestCase {

    override func tearDown() { DisplayAccessibility.override = nil; super.tearDown() }

    private var battery: BatteryMenuModel {
        BatteryMenuModel(powerSource: "Battery", modes: [.init(id: "automatic", title: "Automatic", isSelected: true)], energyApps: [])
    }

    private var sound: SoundMenuModel {
        SoundMenuModel.merge(outputs: [OutputDevice(id: "a", name: "Speakers", kind: .speakers)], defaultID: "a", volume: 0.5, muted: false,
                             batteries: [], apple: nil, expanded: nil)
    }

    func testTheBatteryMenuIsGlassByDefault_SolidUnderReduceTransparency() {
        let view = BatteryMenuContentView()
        DisplayAccessibility.override = DisplayAccessibility()
        view.apply(battery)
        XCTAssertFalse(view.isSolid)
        DisplayAccessibility.override = DisplayAccessibility(reduceTransparency: true)
        view.apply(battery)   // the same model: the change of setting is what draws it again
        XCTAssertTrue(view.isSolid)
        DisplayAccessibility.override = DisplayAccessibility()
        view.apply(battery)
        XCTAssertFalse(view.isSolid, "and back when it is turned off")
    }

    func testTheSoundMenuIsGlassByDefault_SolidUnderReduceTransparency() {
        let view = SoundMenuContentView()
        DisplayAccessibility.override = DisplayAccessibility()
        view.apply(sound)
        XCTAssertFalse(view.isSolid)
        DisplayAccessibility.override = DisplayAccessibility(reduceTransparency: true)
        view.apply(sound)
        XCTAssertTrue(view.isSolid)
        DisplayAccessibility.override = DisplayAccessibility()
        view.apply(sound)
        XCTAssertFalse(view.isSolid)
    }

    func testTheOtherTwoSettingsDoNotMakeThePanelSolid() {
        let view = BatteryMenuContentView()
        DisplayAccessibility.override = DisplayAccessibility(increaseContrast: true, reduceMotion: true)
        view.apply(battery)
        XCTAssertFalse(view.isSolid)
    }

    // ── Pressing an app of the energy list ──────────────────────────────────

    private func descendants(of view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap { descendants(of: $0) } }

    /// The row's press (a click, or VoiceOver's) reaches the controller with the app's name.
    func testPressingAnEnergyAppRowOpensTheLedgerOnThatApp() throws {
        let (defaults, suite) = try TestDefaults.make(owner: "BatteryMenuView", test: name)
        defer { TestDefaults.destroy(defaults, suite) }
        var opened: [String] = []
        let controller = BatteryMenuController(settings: Settings(defaults: defaults), driver: SoundMenuControllerTests.FakeDriver(),
                                               accessibility: { true }, presenter: BatteryMenuControllerTests.FakePresenter(),
                                               native: SoundMenuControllerTests.FakeNative(), pollInterval: 0, followUpDelay: 0,
                                               openLedger: { opened.append($0) })
        let view = BatteryMenuContentView()
        view.controller = controller
        var model = battery
        model.energyApps = [.init(name: "Safari", stats: nil), .init(name: "Mail", stats: nil)]
        view.apply(model)
        let rows = descendants(of: view).compactMap { $0 as? EnergyAppRow }
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows[1].accessibilityPerformPress())
        XCTAssertEqual(opened, ["Mail"])
    }
}
