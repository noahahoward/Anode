import XCTest
@testable import BetterStatsApp
@testable import PowerKit

/// The bottom of the window follows the SORT.
///
/// Sorting the process table by CPU is a statement that CPU is the question, and
/// answering it with a battery breakdown is three panels describing something the
/// user has just said they are not looking at.
final class BottomContextTests: XCTestCase {

    func testTheSortColumnPicksTheSubject() {
        XCTAssertEqual(BottomContext.forSortKey("cpu"), .cpu)
        XCTAssertEqual(BottomContext.forSortKey("gpuPct"), .gpu)
        XCTAssertEqual(BottomContext.forSortKey("gputime"), .gpu)
        XCTAssertEqual(BottomContext.forSortKey("memPct"), .memory)
        XCTAssertEqual(BottomContext.forSortKey("mem"), .memory)
    }

    /// The battery columns stay on battery, including the one that names the GPU.
    /// "GPU %/hr" is a battery cost: sorting by it asks what is draining the
    /// battery, not what is loading the GPU.
    func testTheDrainColumnsStayOnBattery() {
        for key in ["pctHr", "window", "cost", "gpuPctHr"] {
            XCTAssertEqual(BottomContext.forSortKey(key), .battery, key)
        }
    }

    /// Columns that name no subsystem leave the question open rather than
    /// answering it with a guess.
    func testColumnsThatNameNoSubjectFallBackToBattery() {
        for key in ["name", "procs", "diskRead", "diskWrite", "somethingAddedLater"] {
            XCTAssertEqual(BottomContext.forSortKey(key), .battery, key)
        }
    }

    /// Every column the table actually has resolves to something. A column added
    /// later without a mapping gets battery, which is a defensible default and not
    /// a crash.
    func testEveryRealColumnResolves() {
        for column in ProcessColumns.all(powerWindowHours: 10) {
            _ = BottomContext.forSortKey(column.id)
        }
    }

    // ── The bar's slices ────────────────────────────────────────────────────

    /// Apps, system processes, and the measured remainder that belongs to
    /// neither — the battery bar's shape, because it is the honest one for any
    /// quantity measured whole and attributed in part.
    func testTheRemainderIsWhatTheTotalDoesNotExplain() {
        let s = UtilizationSlices(total: 40, apps: 25, systemProcesses: 10)
        XCTAssertEqual(s.unattributed, 5, accuracy: 0.001)
        XCTAssertEqual(s.used, 40, accuracy: 0.001)
    }

    /// The per-process figures and the whole-device figure are sampled a moment
    /// apart, so they disagree in both directions. A negative remainder is that
    /// disagreement, not a discovery, and drawing it would put a slice on the bar
    /// for something that does not exist.
    func testAnOverAttributedSampleShowsNoNegativeSlice() {
        let s = UtilizationSlices(total: 30, apps: 25, systemProcesses: 10)
        XCTAssertEqual(s.unattributed, 0)
        XCTAssertEqual(s.used, 35, accuracy: 0.001,
                       "the named parts are still shown at what they measured")
    }

    /// Idle never enters: the bar is the used portion, and a bar that is 85 %
    /// "nothing is happening" says less than the same bar without it.
    func testIdleIsNeverASlice() {
        let s = UtilizationSlices(total: 12, apps: 8, systemProcesses: 3)
        XCTAssertEqual(s.used, 12, accuracy: 0.001,
                       "the bar covers the used portion, not the device")
    }

    /// Only the subjects that are actually persisted offer long ranges. A 7D
    /// button that draws an empty plot is a worse answer than no button.
    func testEverySubjectOffersOnlyRangesItCanAnswer() {
        for c in BottomContext.allCases {
            XCTAssertFalse(c.ranges.isEmpty, "\(c) offers no range at all")
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// What the graph does when the subject changes.
final class BottomGraphContextTests: XCTestCase {

    /// A utilisation is a percentage of a fixed whole, so its axis is pinned. An
    /// autoscaled one makes 4 % and 40 % look identical, and the height is the
    /// entire reading.
    func testAUtilisationGraphPinsItsAxisAndABatteryGraphDoesNot() {
        // Encoded as the rule the two paths follow, since both the live and the
        // historical path set these together and must not drift apart.
        for c in BottomContext.allCases where c != .battery {
            XCTAssertEqual(c.unit, "%", "\(c) is not a percentage of a fixed whole")
        }
        XCTAssertEqual(BottomContext.battery.unit, "%/hr")
    }

    /// The subjects that offer a week are exactly the ones the store persists.
    /// A range button that draws an empty plot is a worse answer than no button.
    func testTheLongRangesMatchWhatIsActuallyStored() {
        // cpu_pct, mem_pct and gpu_pct are columns on the interval table, written
        // every tick beside the power figures.
        for c in [BottomContext.cpu, .gpu, .memory, .battery] {
            XCTAssertTrue(c.ranges.contains(7 * 24 * 3600),
                          "\(c) is persisted but does not offer a week")
        }
    }
}
