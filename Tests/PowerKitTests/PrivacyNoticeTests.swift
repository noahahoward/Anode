import XCTest
import AppKit
@testable import PowerKit
@testable import AnodeApp

/// The box that says, once for each feature, that macOS will show "Accessing all apps" for Anode while the feature is on.
final class PrivacyNoticeTests: XCTestCase {

    private func summary() -> String {
        "Does a thing. " + PrivacyIndicatorNote.text(while: "this is on", watching: "the keyboard for its shortcut")
    }

    func testItIsSaidOnTheFirstTurningOnAndNotAgain() throws {
        _ = NSApplication.shared
        let (defaults, suite) = try TestDefaults.make(owner: "PrivacyNotice", test: name)
        defer { TestDefaults.destroy(defaults, suite) }
        var shown: [NSAlert] = []
        PrivacyNotice.showOnce(feature: "Window Groups", summary: summary(), defaults: defaults, present: { shown.append($0) })
        XCTAssertEqual(shown.count, 1)
        XCTAssertTrue(shown[0].messageText.contains("Accessing all apps"))
        XCTAssertTrue(shown[0].informativeText.contains("because Anode watches the keyboard for its shortcut"))
        PrivacyNotice.showOnce(feature: "Window Groups", summary: summary(), defaults: defaults, present: { shown.append($0) })
        XCTAssertEqual(shown.count, 1, "turned off and on again, it does not ask again")
    }

    func testEachFeatureSaysItOnce() throws {
        _ = NSApplication.shared
        let (defaults, suite) = try TestDefaults.make(owner: "PrivacyNotice", test: name)
        defer { TestDefaults.destroy(defaults, suite) }
        var count = 0
        for feature in ["Window Groups", "Clipboard History", "Window Groups"] {
            PrivacyNotice.showOnce(feature: feature, summary: summary(), defaults: defaults, present: { _ in count += 1 })
        }
        XCTAssertEqual(count, 2)
    }

    func testAFeatureWhoseDescriptionHasNoSuchSentenceSaysNothing() throws {
        _ = NSApplication.shared
        let (defaults, suite) = try TestDefaults.make(owner: "PrivacyNotice", test: name)
        defer { TestDefaults.destroy(defaults, suite) }
        var count = 0
        PrivacyNotice.showOnce(feature: "Lid Glass", summary: "Does a thing.", defaults: defaults, present: { _ in count += 1 })
        XCTAssertEqual(count, 0)
        XCTAssertFalse(defaults.bool(forKey: PrivacyNotice.key(for: "Lid Glass")), "and notes nothing")
    }
}
