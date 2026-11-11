import XCTest

/// install.sh and uninstall.sh, run for real against a stubbed build in a temporary home (see
/// Tests/installer-tests.sh for what they check and why none of it can touch this Mac). The real
/// compile-and-install variant is `./test.sh --full`.
final class InstallerScriptTests: XCTestCase {

    func testInstallAndUninstallScripts() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = root.appendingPathComponent("Tests/installer-tests.sh")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: script.path),
                          "the installer tests are not in this checkout")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.currentDirectoryURL = root
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Read before waiting: a full pipe would block the script and the wait would never end.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(decoding: data, as: UTF8.self)
        let failures = output.split(separator: "\n").filter { $0.contains("FAIL") }.joined(separator: "\n")
        XCTAssertEqual(process.terminationStatus, 0, "installer tests failed:\n\(failures.isEmpty ? output : failures)")
        XCTAssertTrue(output.contains(" passed, 0 failed"), output)
    }
}
