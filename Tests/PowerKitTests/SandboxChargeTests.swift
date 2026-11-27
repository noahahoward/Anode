import XCTest
@testable import PowerKit
@testable import AnodeApp

/// The test copy `./test.sh --full` installs runs under the person's own account: nothing of it may reach their charge
/// settings. (It did: its uninstall switched macOS's limit off and emptied the record of macOS's own settings.)
final class SandboxChargeTests: XCTestCase {

    func testTheTestCopyHasNoSharedRecord() {
        XCTAssertNil(ChargeRecords.liveStore(sandboxed: true))
        XCTAssertEqual(ChargeRecords.liveStore(sandboxed: false)?.path, "/Users/Shared/Anode/charge-control.json")
    }

    func testTheTestCopyPutsNothingBackWhenItsUninstallerAsks() throws {
        let main = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AnodeApp/main.swift")
        let source = try String(contentsOf: main, encoding: .utf8)
        let asked = try XCTUnwrap(source.range(of: "if CommandLine.arguments.contains(ChargeController.restoreArgument) {"))
        let restore = try XCTUnwrap(source.range(of: "ChargeController.restoreForUninstallOutcome(", range: asked.upperBound..<source.endIndex))
        XCTAssertTrue(source[asked.upperBound..<restore.lowerBound].contains("if AppSandbox.isOn { exit(0) }"))
    }
}
