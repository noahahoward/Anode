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
///
/// The SECOND line of defence. The first is at the source: in a test run `Settings.shared` and `Settings(defaults: nil)`
/// are a throwaway suite of the process's own (`ProcessSettingsTests`), so a spelling this scan cannot read still does
/// not reach the person's. The scan is for the tests that name the real thing at all: it is read over whole files (a
/// line break or any space between the words does not hide a spelling), after comments are taken out.
final class NoSharedSettingsInTestsTests: XCTestCase {

    /// The names under which the person's own settings are kept.
    private static let realDomains = #"(com\.anode\.settings|dev\.anode\.app|com\.betterstats\.settings|dev\.noah\.anode)"#

    /// Spellings that open or default to the real settings (regular expressions over the whole text), and what to write
    /// instead.
    private let forbidden: [(pattern: String, instead: String)] = [
        (#"(?<![A-Za-z0-9_])Settings\s*\.\s*shared\b"#, "throwawaySettings(owner:)"),
        // `let s: Settings = .shared`, `foo(settings: .shared)`: the type is left to be inferred. (String contents are
        // blanked for these: a test of what main.swift says is not doing it.)
        (#"(?<![A-Za-z0-9_])[Ss]ettings\s*[:=]\s*\.shared\b"#, "throwawaySettings(owner:)"),
        (#"(?<![A-Za-z0-9_])Settings\s*\(\s*\)"#, "throwawaySettings(owner:)"),
        (#"(?<![A-Za-z0-9_])Settings\s*\(\s*defaults\s*:\s*nil\s*\)"#, "throwawaySettings(owner:)"),
        (#"(?<![A-Za-z0-9_])Settings\s*\.\s*init\s*\(\s*\)"#, "throwawaySettings(owner:)"),
        (#"BetaFeaturesWindowController\s*\(\s*\)"#, "throwawayBetaWindow(owner:)"),
        (#"defaultFeatures\s*\(\s*hasLidSensor\s*:\s*(true|false)\s*\)"#, "defaultFeatures(hasLidSensor: …, settings: …)"),
        (#"buildGroupMenu\s*\(\s*\)"#, "buildGroupMenu(settings: …)"),
        (#"UserDefaults\s*\.\s*standard"#, "TestDefaults.make(owner:)"),
        (#"\?\?\s*\.standard"#, "TestDefaults.make(owner:)"),
        // Opening the person's suite by name, by the constant or by the literal.
        (#"UserDefaults\s*\(\s*suiteName\s*:\s*Settings\s*\.\s*(suiteName|previousSuiteName)"#, "TestDefaults.make(owner:)"),
        (#"suiteName\s*:\s*""# + realDomains + #"""#, "TestDefaults.make(owner:)"),
        (#"(persistentDomain|removePersistentDomain|setPersistentDomain)\s*\(\s*(forName\s*:\s*)?(Settings\s*\.\s*(suiteName|previousSuiteName)|""# + realDomains + #"")"#, "TestDefaults.make(owner:)"),
        // A suite no one removes: every test suite is made through `TestDefaults`.
        (#"UserDefaults\s*\(\s*suiteName\s*:"#, "TestDefaults.make(owner:), .throwaway(_:) or .named(_:)"),
    ]

    /// The text with comments taken out (a comment says what not to do; it is not doing it) and, unless `keepStrings`,
    /// the contents of string literals blanked.
    static func codeOnly(_ text: String, keepStrings: Bool) -> String {
        var out = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var code = String(line)
            if let r = code.range(of: #"(^|\s)//"#, options: .regularExpression) {
                code = String(code[code.startIndex..<r.lowerBound])
            }
            out += code + "\n"
        }
        if keepStrings { return out }
        return out.replacingOccurrences(of: #""(?:[^"\\\n]|\\.)*""#, with: "\"\"", options: .regularExpression)
    }

    /// What the scan reports for a text, as `line: spelling` entries.
    static func findings(in text: String, forbidden: [(pattern: String, instead: String)]) -> [String] {
        let withStrings = codeOnly(text, keepStrings: true)
        let withoutStrings = codeOnly(text, keepStrings: false)
        var found: [String] = []
        for (pattern, instead) in forbidden {
            // Only the spellings that are a string (a domain's name) are looked for inside strings.
            let code = pattern.contains(#"""#) ? withStrings : withoutStrings
            guard let regex = try? NSRegularExpression(pattern: pattern) else {
                found.append("the pattern \(pattern) is not a regular expression")
                continue
            }
            let ns = code as NSString
            for m in regex.matches(in: code, range: NSRange(location: 0, length: ns.length)) {
                let line = ns.substring(to: m.range.location).filter { $0 == "\n" }.count + 1
                let spelling = ns.substring(with: m.range).replacingOccurrences(of: "\n", with: "⏎")
                found.append("\(line): \(spelling)  → use \(instead)")
            }
        }
        return found
    }

    func testNoTestOpensTheSharedSettingsOrDefaultsToThem() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        // This file names every spelling it forbids, and `TestDefaults.swift` is the one place a suite is opened.
        // `ProcessSettingsTests.swift` uses `Settings.shared` on purpose, to show that it is not the person's.
        let exempt: Set<String> = ["ThrowawaySettings.swift", "TestDefaults.swift", "ProcessSettingsTests.swift"]
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && !exempt.contains($0.lastPathComponent) }
        XCTAssertGreaterThan(files.count, 100, "the scan found no tests")
        var found: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            found += Self.findings(in: text, forbidden: forbidden).map { "\(file.lastPathComponent):\($0)" }
        }
        XCTAssertTrue(found.isEmpty, "a test reaches the person's own settings:\n" + found.joined(separator: "\n"))
    }

    /// The scan sees each spelling a reviewer got past the first version of it.
    func testTheScanSeesEverySpellingOfTheSharedSettings() {
        let bad = [
            "let s = Settings.shared",
            "let s: Settings = .shared",
            "let s = Settings\n    .shared",
            "let s = Settings . shared",
            "let _: Settings = .shared",
            "foo(settings: .shared)",
            "let s = Settings(defaults: nil)",
            "let s = Settings( defaults : nil )",
            "let s = Settings()",
            "let s = Settings.init()",
            "let d = UserDefaults(suiteName: Settings.suiteName)",
            "let d = UserDefaults(suiteName: Settings\n    .suiteName)",
            "let d = UserDefaults(suiteName: \"com.anode.settings\")",
            "let d = UserDefaults(suiteName: \"dev.anode.app\")",
            "let d = UserDefaults(suiteName:\n    \"com.anode.settings\")",
            "UserDefaults.standard.set(1, forKey: \"k\")",
            "UserDefaults(suiteName: \"mine-\\(UUID())\")",
            "d.removePersistentDomain(forName: \"dev.anode.app\")",
            "d.removePersistentDomain(forName: Settings.suiteName)",
        ]
        for text in bad {
            XCTAssertFalse(Self.findings(in: text, forbidden: forbidden).isEmpty, "not seen: \(text)")
        }
        let fine = [
            "let s = Settings(defaults: defaults)",
            "// let s = Settings.shared",
            "let w = NSWorkspace.shared",
            "let bundleID = \"dev.anode.app\"",
            "XCTAssertNotEqual(LoginAgent.label, \"dev.anode.app\")",
            "let live = [Settings.suiteName, Settings.previousSuiteName]",
            "XCTAssertTrue(main.contains(\"ChargeController(settings: .shared, records: chargeRecords\"))",
            "FanControlPanel(frame: f, settings: s, link: .shared)",
        ]
        for text in fine {
            XCTAssertTrue(Self.findings(in: text, forbidden: forbidden).isEmpty,
                          "refused: \(text): \(Self.findings(in: text, forbidden: forbidden))")
        }
    }
}
