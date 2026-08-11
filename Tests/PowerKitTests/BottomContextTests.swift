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
        for key in ["name", "procs", "somethingAddedLater"] {
            XCTAssertEqual(BottomContext.forSortKey(key), .battery, key)
        }
    }

    /// Both disk columns land on one subject, whose graph draws both lines.
    /// Sorting by writes says disk is the question, not that reads stopped
    /// mattering — and the two come off the same counter pair on the same tick.
    func testBothDiskColumnsShareOneSubject() {
        XCTAssertEqual(BottomContext.forSortKey("diskRead"), .disk)
        XCTAssertEqual(BottomContext.forSortKey("diskWrite"), .disk)
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
    ///
    /// Disk is the exception and has to be: bytes per second has no ceiling to
    /// divide by, so it autoscales. `isPercentage` is the flag both the live and
    /// the historical path read, so it is what this asserts against rather than
    /// re-listing the cases — a subject added later gets caught by the unit check
    /// below instead of silently pinning its axis at 100.
    func testAUtilisationGraphPinsItsAxisAndABatteryGraphDoesNot() {
        for c in BottomContext.allCases where c.isPercentage && c != .battery {
            XCTAssertEqual(c.unit, "%", "\(c) claims to be a percentage")
        }
        XCTAssertEqual(BottomContext.battery.unit, "%/hr")
        XCTAssertFalse(BottomContext.disk.isPercentage,
                       "a byte rate has no ceiling to be a percentage of")
        XCTAssertEqual(BottomContext.disk.unit, "B/s")
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

// ─────────────────────────────────────────────────────────────────────────────

/// The bar and the card, for a subject that is not the battery.
final class BottomPanelTests: XCTestCase {

    private func sys(cpu: CPUUsage.Sample? = nil,
                     memory: MemoryUsage.Sample? = nil,
                     disk: DiskActivity.Sample? = nil) -> SystemMetrics.Snapshot {
        SystemMetrics.Snapshot(cpu: cpu, memory: memory, gpu: nil, network: nil,
                               disk: disk, cpuTemperature: nil, gpuTemperature: nil,
                               fans: [])
    }

    /// Memory is cut by KIND, not into apps and daemons — the kernel reports it
    /// that way and it is the more useful cut: wired cannot be paged out, and
    /// compressed is pressure that has already happened.
    func testTheMemoryBarIsCutByKindAndHasNothingUnattributed() {
        let bar = LedgerBarView.UtilizationBar.memory(app: 30, wired: 12, compressed: 5)
        XCTAssertEqual(bar.parts.map(\.title), ["app", "wired", "compressed"])
        XCTAssertEqual(bar.used, 47, accuracy: 0.001)
        XCTAssertFalse(bar.parts.contains { $0.hatched },
                       "memory has no unattributed part to hatch")
    }

    /// CPU and GPU keep the battery bar's shape, including the hatched remainder:
    /// something measured whole, attributed in part, with the rest shown rather
    /// than folded into a neighbour.
    func testAnAttributedBarAlwaysMarksItsRemainder() {
        let bar = LedgerBarView.UtilizationBar.attributed(
            "CPU", UtilizationSlices(total: 40, apps: 25, systemProcesses: 10))
        XCTAssertEqual(bar.parts.map(\.title), ["apps", "system processes", "unattributed"])
        XCTAssertTrue(bar.parts.last?.hatched ?? false,
                      "the part that could not be named is not marked as such")
        XCTAssertEqual(bar.used, 40, accuracy: 0.001)
    }

    /// The GPU bar says its split is slower than its total. Per-app GPU is a
    /// coalition rollup at ~30-60 s while the device figure is read every tick,
    /// so the parts step while the whole moves — which looks like a stall.
    func testTheGPUBarDisclosesItsSlowerAttribution() {
        let bar = LedgerBarView.UtilizationBar.attributed(
            "GPU", UtilizationSlices(total: 20, apps: 12, systemProcesses: 3),
            note: "per-app GPU updates every ~30-60 s")
        XCTAssertNotNil(bar.attributionNote)
        // And the CPU bar does not, because its parts and its whole are both read
        // every tick.
        XCTAssertNil(LedgerBarView.UtilizationBar.attributed(
            "CPU", UtilizationSlices(total: 20, apps: 12, systemProcesses: 3)).attributionNote)
    }

    /// The card states the same number its headline does, and names its facts.
    func testTheCPUCardShowsTheChipAndTheSplit() throws {
        let s = sys(cpu: CPUUsage.Sample(total: 16.4, user: 12.4, system: 4.1,
                                         idle: 83.6, interval: 2))
        let m = try XCTUnwrap(GlanceCardView.model(for: .cpu, system: s,
                                                   facts: MachineInfo.facts, census: nil))
        XCTAssertEqual(m.headline, "16.4%")
        XCTAssertEqual(m.pill, "16%", "the pill disagrees with the headline")
        let labels = m.rows.map(\.label)
        XCTAssertTrue(labels.contains("Chip"))
        XCTAssertTrue(labels.contains("User"))
        XCTAssertTrue(labels.contains("System"))
    }

    /// Disk keeps the attributed shape but counts in bytes per second, and it has
    /// to: there is no ceiling to divide by, so nothing here is a percentage.
    func testTheDiskBarCountsInBytesRatherThanPercent() {
        let bar = LedgerBarView.UtilizationBar.attributed(
            "Disk", UtilizationSlices(total: 4_194_304, apps: 1_048_576,
                                      systemProcesses: 524_288),
            scale: .bytesPerSecond)
        XCTAssertEqual(bar.parts.map(\.title), ["apps", "system processes", "unattributed"])
        XCTAssertEqual(bar.scale, .bytesPerSecond)
        // Through the app's own byte formatter, so the bar and the Disk columns
        // cannot disagree about what a megabyte is — this app counts in 1024s, and
        // a hand-rolled divisor here is how "977KB/s" and "1.0MB/s" end up side by
        // side on one screen.
        XCTAssertEqual(bar.scale(1_048_576), "1.0MB/s")
        XCTAssertEqual(bar.scale(1_048_576),
                       MetricUnit.bytesPerSecond.format(1_048_576))
    }

    /// The axis plots MiB/s and says "MB/s", which is only honest because the rest
    /// of the app means 1024² by "MB" too. A 1000-based axis beside a 1024-based
    /// column is a 5 % disagreement nobody would ever track down.
    func testTheDiskAxisAgreesWithTheAppsByteUnits() {
        XCTAssertEqual(AppDelegate.mib(1_048_576), 1, accuracy: 1e-9)
        XCTAssertEqual(AppDelegate.diskAxisLabel, "MB/s")
        XCTAssertTrue(MetricUnit.bytesPerSecond.format(1_048_576).hasSuffix("MB/s"))
    }

    /// Two lines, and the same two whether they came from the live buffer or the
    /// store. The live charge line stayed the wrong colour for a whole release
    /// because the 1H view and the longer views built their series separately.
    func testTheDiskGraphDrawsReadAndWriteInDistinctInks() {
        let series = AppDelegate.diskSeries(
            read: [.init(time: Date(), value: 1)],
            write: [.init(time: Date(), value: 2)])
        XCTAssertEqual(series.map { $0.name }, ["read", "write"])
        XCTAssertNotEqual(series[0].color, series[1].color)
        XCTAssertFalse(series.contains { $0.filled == true },
                       "two filled areas overlap into a third apparent value")
    }

    /// Disk states a rate, so it has no percentage to put in the pill — and the
    /// pill used to be an `Int` with the "%" written into the view, which assumed
    /// every subject was one.
    func testTheDiskCardStatesARateAndClaimsNoPercentage() throws {
        let s = sys(disk: DiskActivity.Sample(bytesReadPerSec: 3_145_728,
                                              bytesWrittenPerSec: 1_048_576,
                                              devices: [], interval: 2))
        let m = try XCTUnwrap(GlanceCardView.model(for: .disk, system: s,
                                                   facts: MachineInfo.facts, census: nil))
        XCTAssertEqual(m.headline, MetricUnit.bytesPerSecond.format(4_194_304))
        XCTAssertNil(m.pill, "there is no honest disk-busy percentage to show")
        let labels = m.rows.map(\.label)
        XCTAssertTrue(labels.contains("Read"))
        XCTAssertTrue(labels.contains("Write"))
    }

    /// And a subject with no reading yet returns nil so the caller can fall back
    /// to the battery, rather than inventing a card of zeroes.
    func testASubjectWithNoReadingYieldsNoCard() {
        XCTAssertNil(GlanceCardView.model(for: .cpu, system: sys(),
                                          facts: MachineInfo.facts, census: nil))
        XCTAssertNil(GlanceCardView.model(for: .memory, system: sys(),
                                          facts: MachineInfo.facts, census: nil))
        XCTAssertNil(GlanceCardView.model(for: .battery, system: sys(),
                                          facts: MachineInfo.facts, census: nil),
                     "battery is the fallback, not something this builds")
    }
}
