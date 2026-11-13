import XCTest

/// `test.sh` stops a run in which one test case hangs, and names it (see Tests/watchdog-tests.sh). `swift test` does not
/// enforce `executionTimeAllowance` here, so without this a test that waits for a socket nobody answers hangs the suite.
final class TestRunnerWatchdogTests: XCTestCase {

    func testTheRunnerStopsAndNamesATestThatNeverEnds() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = root.appendingPathComponent("Tests/watchdog-tests.sh")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: script.path),
                          "the watchdog tests are not in this checkout")

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
        XCTAssertEqual(process.terminationStatus, 0, "watchdog tests failed:\n\(failures.isEmpty ? output : failures)")
        XCTAssertTrue(output.contains(" passed, 0 failed"), output)
    }
}
