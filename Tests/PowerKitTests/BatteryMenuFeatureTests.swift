import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// The Battery Menu section of Beta Features: one switch, and a line saying what is missing.
final class BatteryMenuFeatureTests: XCTestCase {

    private func rig(trusted: Bool = true) throws -> (feature: BatteryMenuFeature, settings: Settings, cleanup: () -> Void) {
        let (defaults, suite) = try TestDefaults.make(owner: "BatteryMenuUI", test: name)
        let settings = Settings(defaults: defaults)
        let feature = BatteryMenuFeature(settings: settings, accessibility: { trusted })
        _ = feature.makeView()
        return (feature, settings, { TestDefaults.destroy(defaults, suite) })
    }

    func testItIsOffByDefaultAndTheCheckboxWritesTheSetting() throws {
        let r = try rig(); defer { r.cleanup() }
        XCTAssertEqual(r.feature.enableCheckbox.state, .off)
        XCTAssertFalse(r.settings.batteryMenuEnabled)
        r.feature.enableCheckbox.performClick(nil)
        XCTAssertTrue(r.settings.batteryMenuEnabled)
        r.feature.enableCheckbox.performClick(nil)
        XCTAssertFalse(r.settings.batteryMenuEnabled)
    }

    func testTheCheckboxFollowsTheSetting() throws {
        let r = try rig(); defer { r.cleanup() }
        r.settings.batteryMenuEnabled = true
        XCTAssertEqual(r.feature.enableCheckbox.state, .on)
    }

    func testWithoutAccessibilityItSaysSoAndOffersTheSettings() throws {
        let r = try rig(trusted: false); defer { r.cleanup() }
        XCTAssertTrue(r.feature.accessibilityButton.isHidden, "nothing to fix while it is off")
        r.settings.batteryMenuEnabled = true
        r.feature.refresh()
        XCTAssertFalse(r.feature.accessibilityButton.isHidden)
        XCTAssertTrue(r.feature.statusLabel.stringValue.contains("Accessibility"))
    }

    func testItIsAmongTheDefaultSections() throws {
        let (defaults, suite) = try TestDefaults.make(owner: "BatteryMenuUI", test: name)
        defer { TestDefaults.destroy(defaults, suite) }
        let titles = BetaFeaturesWindowController.defaultFeatures(hasLidSensor: false, settings: Settings(defaults: defaults)).map(\.title)
        XCTAssertTrue(titles.contains("Battery Menu"))
    }
}
