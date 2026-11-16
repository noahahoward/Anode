import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// The Sound menu as the app builds it: the drawn menu knows its controller, nothing starts while the setting is off, and a
/// quit closes macOS's own panel.
final class SoundMenuWiringTests: XCTestCase {

    private typealias Fakes = SoundMenuControllerTests

    func testRuntimeConnectsTheDrawnMenuToItsController() throws {
        let (defaults, suite) = try TestDefaults.make(owner: "SoundMenuWiring", test: name); defer { TestDefaults.destroy(defaults, suite) }
        let panel = SoundMenuPanel()
        let outputs = Fakes.FakeOutputs()
        let c = SoundMenuRuntime.make(settings: Settings(defaults: defaults), outputs: outputs, driver: Fakes.FakeDriver(),
                                      statusBar: Fakes.FakeBar(), panel: panel)
        XCTAssertTrue(panel.controller === c)
        XCTAssertFalse(outputs.started, "nothing runs while the setting is off")
    }

    func testQuitStopsEverythingOfTheMenu() throws {
        let (defaults, suite) = try TestDefaults.make(owner: "SoundMenuWiring", test: name); defer { TestDefaults.destroy(defaults, suite) }
        let settings = Settings(defaults: defaults); settings.soundMenuEnabled = true
        let outputs = Fakes.FakeOutputs(), driver = Fakes.FakeDriver(), bar = Fakes.FakeBar()
        let c = SoundMenuRuntime.make(settings: settings, outputs: outputs, driver: driver, statusBar: bar, panel: SoundMenuPanel())
        XCTAssertTrue(outputs.started)
        c.stop()
        XCTAssertFalse(outputs.started)
        XCTAssertTrue(driver.cancelled)
        XCTAssertTrue(bar.items[0].removed)
    }
}
