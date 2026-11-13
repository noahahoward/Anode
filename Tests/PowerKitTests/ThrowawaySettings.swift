import XCTest
@testable import AnodeApp
@testable import PowerKit

/// Settings and windows for tests that need the app's own sections but must not read or write the person's settings.
///
/// `Settings.shared` is the app's real settings suite (`com.anode.settings`), and so are the defaults of every section
/// and window built without being given settings: a test that builds one reads the person's settings, and one that
/// toggles a checkbox writes them. A test of that kind makes its own, on a throwaway suite (`TestDefaults`), removed
/// when the test ends.
extension XCTestCase {

    /// Settings on a throwaway suite of the test's own, removed when it ends.
    func throwawaySettings(owner: String, test: String = #function) throws -> Settings {
        let (defaults, name) = try TestDefaults.make(owner: owner, test: test)
        addTeardownBlock { TestDefaults.destroy(defaults, name) }
        return Settings(defaults: defaults)
    }

    /// The Beta Features window over the default sections, built on throwaway settings.
    func throwawayBetaWindow(owner: String, test: String = #function) throws -> BetaFeaturesWindowController {
        BetaFeaturesWindowController(settings: try throwawaySettings(owner: owner, test: test))
    }
}

/// No test reaches the person's settings by the back door. A scan of the test target's own text, because the way they
/// were reached was a default argument: `BetaFeaturesWindowController()` read the shared settings in thirteen tests
/// that never mentioned them.
final class NoSharedSettingsInTestsTests: XCTestCase {

    /// Spellings that open or default to the real settings (regular expressions), and what to write instead.
    private let forbidden: [(pattern: String, instead: String)] = [
        (#"(?<![A-Za-z0-9_])Settings\.shared"#, "throwawaySettings(owner:)"),
        (#"(?<![A-Za-z0-9_])Settings\(\)"#, "throwawaySettings(owner:)"),
        (#"BetaFeaturesWindowController\(\)"#, "throwawayBetaWindow(owner:)"),
        (#"defaultFeatures\(hasLidSensor: (true|false)\)"#, "defaultFeatures(hasLidSensor: …, settings: …)"),
        (#"buildGroupMenu\(\)"#, "buildGroupMenu(settings: …)"),
        (#"UserDefaults\.standard"#, "TestDefaults.make(owner:)"),
        (#"\?\? \.standard"#, "TestDefaults.make(owner:)"),
    ]

    func testNoTestOpensTheSharedSettingsOrDefaultsToThem() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != #fileID.split(separator: "/").last.map(String.init) }
        XCTAssertGreaterThan(files.count, 100, "the scan found no tests")
        var found: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            for (i, line) in lines.enumerated() {
                let code = line.drop { $0 == " " }
                // Comments say what not to do; they are not doing it.
                if code.hasPrefix("//") || code.hasPrefix("///") { continue }
                let text = String(line)
                for (pattern, instead) in forbidden
                where text.range(of: pattern, options: .regularExpression) != nil {
                    found.append("\(file.lastPathComponent):\(i + 1): \(text.trimmingCharacters(in: .whitespaces))  → use \(instead)")
                }
            }
        }
        XCTAssertTrue(found.isEmpty, "a test reaches the person's own settings:\n" + found.joined(separator: "\n"))
    }
}
