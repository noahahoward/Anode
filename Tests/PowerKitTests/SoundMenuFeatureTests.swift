import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// The Sound Menu section of Beta Features: one switch, and a line saying what is missing.
final class SoundMenuFeatureTests: XCTestCase {

    private func rig(trusted: Bool = true) throws -> (feature: SoundMenuFeature, settings: Settings, cleanup: () -> Void) {
        let (defaults, suite) = try TestDefaults.make(owner: "SoundMenuUI", test: name)
        let settings = Settings(defaults: defaults)
        let feature = SoundMenuFeature(settings: settings, accessibility: { trusted })
        _ = feature.makeView()
        return (feature, settings, { TestDefaults.destroy(defaults, suite) })
    }

    func testCheckboxWritesSetting() throws {
        let r = try rig(); defer { r.cleanup() }
        XCTAssertEqual(r.feature.enableCheckbox.state, .off)
        r.feature.enableCheckbox.performClick(nil)
        XCTAssertTrue(r.settings.soundMenuEnabled)
        r.feature.enableCheckbox.performClick(nil)
        XCTAssertFalse(r.settings.soundMenuEnabled)
    }

    func testNativeIconCheckboxWritesAndFollowsTheSetting() throws {
        let r = try rig(); defer { r.cleanup() }
        XCTAssertEqual(r.feature.nativeIconCheckbox.state, .off)
        XCTAssertFalse(r.feature.nativeIconCheckbox.isEnabled, "greyed out while the menu itself is off")
        r.settings.soundMenuEnabled = true
        r.feature.refresh()
        XCTAssertTrue(r.feature.nativeIconCheckbox.isEnabled)
        r.feature.nativeIconCheckbox.performClick(nil)
        XCTAssertTrue(r.settings.soundMenuUsesNativeIcon)
        r.settings.soundMenuUsesNativeIcon = false
        r.feature.refresh()
        XCTAssertEqual(r.feature.nativeIconCheckbox.state, .off)
    }

    func testCheckboxFollowsSetting() throws {
        let r = try rig(); defer { r.cleanup() }
        r.settings.soundMenuEnabled = true
        r.feature.refresh()
        XCTAssertEqual(r.feature.enableCheckbox.state, .on)
    }

    func testWithoutAccessibilitySaysAppleRowsNeedIt() throws {
        let r = try rig(trusted: false); defer { r.cleanup() }
        r.settings.soundMenuEnabled = true
        r.feature.refresh()
        XCTAssertTrue(r.feature.statusLabel.stringValue.contains("Accessibility"))
    }

    func testOffSaysOff() throws {
        let r = try rig(trusted: false); defer { r.cleanup() }
        XCTAssertEqual(r.feature.statusLabel.stringValue, "Off.")
    }

    func testListedInDefaultFeaturesAfterTheHider() throws {
        let (defaults, suite) = try TestDefaults.make(owner: "SoundMenuList", test: name); defer { TestDefaults.destroy(defaults, suite) }
        let list = BetaFeaturesWindowController.defaultFeatures(hasLidSensor: false, settings: Settings(defaults: defaults))
        let titles = list.map(\.title)
        let hider = try XCTUnwrap(titles.firstIndex(of: "Menu Bar Hider"))
        XCTAssertEqual(titles[hider + 1], "Sound Menu")
    }
}
