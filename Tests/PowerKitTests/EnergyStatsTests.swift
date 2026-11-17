import XCTest
@testable import PowerKit

/// What Anode adds to an app under "Using Significant Energy": its measured drain, on the right of its row.
final class EnergyStatsTests: XCTestCase {

    func testTheRowSaysTheDrainAndTheCPU() {
        let s = EnergyStats(pctPerHour: 0.324, cpuPercent: 4.09, memoryBytes: 4_500_000_000, minutesBack: 2)
        XCTAssertEqual(s.rowText, "0.32 %/hr · 4.1% CPU")
    }

    func testAVerySmallDrainIsSaidAsLessThanTheSmallestFigure() {
        XCTAssertEqual(EnergyStats(pctPerHour: 0.004, cpuPercent: 0.2, memoryBytes: 0, minutesBack: nil).rowText, "<0.01 %/hr · 0.2% CPU")
    }

    func testBigCPUIsWholePercent() {
        XCTAssertEqual(EnergyStats(pctPerHour: 3.2, cpuPercent: 37.6, memoryBytes: 0, minutesBack: nil).rowText, "3.20 %/hr · 38% CPU")
    }

    func testTheTooltipHasEverythingAnodeKnows() {
        let s = EnergyStats(pctPerHour: 0.32, cpuPercent: 4.1, memoryBytes: 4_500_000_000, minutesBack: 2.4)
        XCTAssertTrue(s.tooltip.contains("0.32 %/hr"))
        XCTAssertTrue(s.tooltip.contains("4.1% of the CPU"))
        XCTAssertTrue(s.tooltip.contains("4.5 GB"))
        XCTAssertTrue(s.tooltip.contains("2 min"), "what quitting it would buy back")
    }

    func testTheTooltipLeavesOutWhatIsNotKnown() {
        let s = EnergyStats(pctPerHour: 0.32, cpuPercent: 4.1, memoryBytes: 0, minutesBack: nil)
        XCTAssertFalse(s.tooltip.contains("memory"))
        XCTAssertFalse(s.tooltip.contains("min"))
    }

    func testAnHourOrMoreOfRuntimeIsSaidInHours() {
        let s = EnergyStats(pctPerHour: 5, cpuPercent: 50, memoryBytes: 0, minutesBack: 75)
        XCTAssertTrue(s.tooltip.contains("1h 15m"))
    }
}
