import XCTest
@testable import PowerKit
@testable import AnodeApp

/// A leak finding is withdrawn when the memory falls back: the fixture starts at 200 MiB and is flagged at +100 MiB, so
/// 250 MiB or less is "gave back at least half". A leak keeps what it took.
final class LeakRecoveryTests: XCTestCase {

    private let mib: UInt64 = 1 << 20

    func testHalfOfTheGrowthGivenBackIsRecovered() {
        let f = makeLeakFinding()
        XCTAssertFalse(f.hasRecovered(currentBytes: 300 * mib), "where it was flagged")
        XCTAssertFalse(f.hasRecovered(currentBytes: 251 * mib))
        XCTAssertTrue(f.hasRecovered(currentBytes: 250 * mib))
        XCTAssertTrue(f.hasRecovered(currentBytes: 40 * mib), "far below the start too")
    }

    func testALowMemoryWarningIsNeverWithdrawnThisWay() {
        XCTAssertFalse(makePressureFinding().hasRecovered(currentBytes: 0))
    }

    func testAFindingWithNoGrowthHasNothingToGiveBack() {
        var f = makeLeakFinding()
        f.netGrowthBytes = 0
        XCTAssertFalse(f.hasRecovered(currentBytes: 0))
    }

    func testTheWindowSaysSoWhenTheLatestPointIsLow() {
        let f = makeLeakFinding()
        let high = MemoryWatchWindowModel(finding: f, live: [MemorySample(seconds: 2000, bytes: 300 * mib)])
        XCTAssertFalse(high.recovered)
        XCTAssertEqual(high.headingText, MemoryWatchWindowModel.heading)
        let low = MemoryWatchWindowModel(finding: f, live: [MemorySample(seconds: 2000, bytes: 220 * mib)])
        XCTAssertTrue(low.recovered)
        XCTAssertEqual(low.headingText, MemoryWatchWindowModel.recoveredHeading)
        XCTAssertEqual(low.windowTitle, MemoryWatchWindowModel.recoveredWindowTitle)
        XCTAssertTrue(low.explanation.contains("probably not a leak"), low.explanation)
        XCTAssertTrue(low.explanation.contains("fallen back"), low.explanation)
    }

    func testTheBadgeDropsOutOnceTheProcessIsLow() {
        // The real check reads the process; here only the finding's own rule is exercised through the seam's logic.
        let f = makeLeakFinding()
        let stillCounts: (UInt64) -> Bool = { !f.hasRecovered(currentBytes: $0) }
        XCTAssertTrue(stillCounts(310 * mib))
        XCTAssertFalse(stillCounts(230 * mib))
    }
}
