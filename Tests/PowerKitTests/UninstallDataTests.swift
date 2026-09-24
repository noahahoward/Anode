import XCTest
@testable import PowerKit

// "Remove my data" has to mean all of it, and the list exists twice — the app's
// uninstall plan and the shell script — kept in step by hand. Every data file the
// app writes to Application Support is named here, and both lists are checked.
final class UninstallDataTests: XCTestCase {

    private let dataFiles = ["history.sqlite", "history.sqlite-wal", "history.sqlite-shm",
                             "discharge-trend.json", "lifetime-drain.json"]

    func testTheAppsPlanRemovesEveryDataFile() {
        let plan = Uninstall.plan(removingData: true, home: "/h", exists: { _ in true })
        let names = Set(plan.data.map { ($0 as NSString).lastPathComponent })
        XCTAssertEqual(names, Set(dataFiles))
    }

    func testKeepingDataKeepsTheLearnedModel() {
        let plan = Uninstall.plan(removingData: false, home: "/h", exists: { _ in true })
        XCTAssertTrue(plan.data.isEmpty)
    }

    func testTheScriptRemovesTheSameFiles() throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("uninstall.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        for f in dataFiles {
            XCTAssertTrue(text.contains("\"$SUPPORT/\(f)\""), "uninstall.sh does not remove \(f)")
        }
    }
}
