import XCTest

/// What the build script says when it has finished, which `install.sh` passes on to whoever installed Anode.
final class BuildScriptWordsTests: XCTestCase {

    private func script() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("build-app.sh"), encoding: .utf8)
    }

    /// The lines it prints: those that begin with `echo "›`.
    private func said() throws -> [String] {
        try script().split(separator: "\n").map(String.init).filter { $0.hasPrefix("echo \"\u{203A}") }
    }

    /// The helper has been the Anode helper since 1.17.0 (one helper for fans, Charge Control and Low Power Mode), and
    /// the closing lines still called it fan control.
    func testTheClosingLinesCallTheHelperByItsName() throws {
        let lines = try said()
        XCTAssertFalse(lines.contains { $0.lowercased().contains("fan control") || $0.lowercased().contains("fan helper") },
                       lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains { $0.contains("the Anode helper") && $0.contains("fans, Charge Control and Low Power Mode") },
                      lines.joined(separator: "\n"))
    }

    /// The app offers the helper itself since 1.18.0, so the lines say so, and keep the command for doing it by hand
    /// and the one that undoes everything.
    func testTheySayTheAppOffersItAndKeepTheCommands() throws {
        let lines = try said()
        XCTAssertTrue(lines.contains { $0.contains("Anode offers to install it the first time it opens") })
        XCTAssertTrue(lines.contains { $0.hasSuffix("AnodeHelper'\"") }, "the command to run it by hand is gone")
        XCTAssertTrue(lines.contains { $0.hasSuffix("AnodeHelper' --uninstall\"") }, "the command that undoes it is gone")
    }
}
