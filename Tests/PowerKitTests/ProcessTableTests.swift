import AppKit
import XCTest
@testable import BetterStatsApp
@testable import PowerKit

// The Processes tab. Five lenses that each re-columned one table became one table
// with all the columns, which moves three things that used to be spread across
// parallel switch statements — what a cell says, what it sorts by, and whether it
// was measured — into one `ProcessColumn`. These assert that the list is the single
// source of truth it claims to be, and that nothing in it renders an absence as a
// zero.

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Fixtures

private func makeApp(name: String,
                     bundleID: String? = nil,
                     isApp: Bool = true,
                     watts: Double = 0.04,
                     pctHr: Double = 0.06,
                     procs: Int = 1,
                     cpu: Double = 12.5,
                     memory: UInt64 = 512 * 1024 * 1024,
                     disk: Double = 0, written: Double = 0) -> AppDrain {
    AppDrain(identity: AppIdentity(name: name, bundlePath: nil,
                                   bundleID: bundleID, isApp: isApp),
             joules: watts * 2,
             watts: watts,
             percentPerHour: pctHr,
             processCount: procs,
             pids: Array(1...max(1, procs)).map { pid_t($0) },
             cpuPercent: cpu,
             memoryBytes: memory,
             diskReadPerSec: disk,
             diskWrittenPerSec: written)
}

/// `gpuRate` defaults to the hour total spread evenly, which is the only case in
/// which the two bases agree — tests that care about the difference state it.
private func makeAttributed(name: String, bundleID: String = "",
                            pctHr: Double = 0.5,
                            gpu_ms: UInt64 = 0,
                            gpuRate: Double? = nil,
                            isSystem: Bool = true) -> SystemAttribution.Row {
    SystemAttribution.Row(bundleID: bundleID, name: name, watts: 0.3,
                          percentPerHour: pctHr, cpu_ms: 100, gpu_ms: gpu_ms,
                          cpuRate_msPerS: 1,
                          gpuRate_msPerS: gpuRate ?? Double(gpu_ms) / 3600,
                          isSystem: isSystem)
}

private func makeRow(app: AppDrain? = nil,
                     system: SystemAttribution.Row? = nil,
                     gpu: SystemAttribution.Row? = nil,
                     gpuTimeShare: Double? = nil,
                     windowPct: Double? = nil,
                     costMin: Double? = nil,
                     totalMemory: UInt64 = 16 * 1024 * 1024 * 1024) -> Row {
    Row(app: app, system: system, gpu: gpu, gpuTimeShare: gpuTimeShare,
        windowPct: windowPct, costMin: costMin, totalMemoryBytes: totalMemory)
}

private func columns() -> [ProcessColumn] { ProcessColumns.all(powerWindowHours: 10) }

private func column(_ id: String) -> ProcessColumn {
    columns().first { $0.id == id }!
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Definitions

final class ProcessColumnDefinitionTests: XCTestCase {

    /// The set and the order the user asked for. Written out rather than derived,
    /// because this list IS the specification — a test that recomputed it from the
    /// implementation would agree with any reordering.
    func testTheColumnsAreTheOnesSpecified() {
        XCTAssertEqual(columns().map(\.id),
                       ["name", "pctHr", "window", "cost", "procs", "cpu",
                        "memPct", "mem", "diskRead", "diskWrite",
                        "gpuPct", "gputime", "gpuPctHr"])
    }

    /// Read and write are DIFFERENT NUMBERS in different columns.
    ///
    /// They used to be summed in `DrainTracker` the moment they were sampled, so
    /// the table could not have told them apart if it wanted to. The regression
    /// this guards is subtle: re-summing anywhere in the chain still produces two
    /// plausible-looking columns, both showing the total.
    func testReadAndWriteAreShownSeparatelyAndNotSummed() {
        let row = makeRow(app: makeApp(name: "Busy", disk: 1_000_000, written: 4_000_000))
        let read = column("diskRead").text(row).text
        let written = column("diskWrite").text(row).text
        // Against the formatter, not against digits: bytesPerSecond is base 2, so
        // 1,000,000 renders "977KB/s" and guessing at a "1" fails for reasons
        // that have nothing to do with the property under test.
        XCTAssertEqual(read, MetricUnit.bytesPerSecond.format(1_000_000))
        XCTAssertEqual(written, MetricUnit.bytesPerSecond.format(4_000_000))
        XCTAssertNotEqual(read, written, "both columns showed the same figure")
        // And neither is the sum, which is what a re-sum anywhere in the chain
        // would produce — twice, plausibly, in both columns.
        let summed = MetricUnit.bytesPerSecond.format(5_000_000)
        XCTAssertNotEqual(read, summed, "the read column is showing read+write")
        XCTAssertNotEqual(written, summed, "the write column is showing read+write")
    }

    /// A process that read nothing and wrote nothing reads "0" in both, not a
    /// dash: it was sampled, and zero is what was measured.
    func testAMeasuredZeroIsAZeroInBothColumns() {
        let row = makeRow(app: makeApp(name: "Idle", disk: 0, written: 0))
        XCTAssertEqual(column("diskRead").text(row).text, "0")
        XCTAssertEqual(column("diskWrite").text(row).text, "0")
    }

    func testEveryColumnIsAddressableExactlyOnce() {
        let ids = columns().map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "two columns share an identifier, "
                     + "so one of them is unreachable through columnsByID")
        XCTAssertEqual(ProcessColumns.byID(10).count, ids.count)
    }

    /// The spacer is not a column. It has no data, must never be sortable, and the
    /// renderer and sizer both skip it by this identifier.
    func testTheSpacerIsNotOneOfTheColumns() {
        XCTAssertFalse(columns().contains { $0.id == ProcessColumns.spacerID })
    }

    /// A twelve-column header cannot say what "%/hr" divides by. The tooltip is the
    /// only place that answer fits, so a column without one is a number with no
    /// stated meaning.
    func testEveryColumnExplainsItself() {
        for c in columns() {
            XCTAssertGreaterThan(c.tooltip.count, 20, "\(c.id) has no usable tooltip")
        }
    }

    /// Per-process GPU is apportioned from a coalition rollup, never measured. All
    /// three GPU columns have to say so, and nothing else may claim to.
    func testOnlyTheGPUColumnsAreMarkedModeled() {
        let modeled = columns().filter(\.isModeled).map(\.id)
        XCTAssertEqual(modeled, ["gpuPct", "gputime", "gpuPctHr"])
        for c in columns().filter(\.isModeled) {
            XCTAssertTrue(c.title.hasSuffix("*"),
                          "\(c.id) is apportioned and its header does not say so")
            // Every one of them has to name the coalition rollup it came from —
            // that IS the modeling, and "*" alone does not say what is modeled.
            XCTAssertTrue(c.tooltip.lowercased().contains("coalition"), c.id)
        }
        for c in columns() where !c.isModeled {
            XCTAssertFalse(c.title.hasSuffix("*"),
                           "\(c.id) is measured and is wearing the estimate mark")
        }
    }

    /// The trailing-window column is TITLED from the setting that defines it. It
    /// used to be the literal "10 hr power", which would have gone on claiming ten
    /// hours over a two-hour figure.
    func testTheWindowColumnIsTitledFromTheSetting() {
        XCTAssertEqual(ProcessColumns.all(powerWindowHours: 10)
                        .first { $0.id == "window" }?.title, "10 hr power")
        XCTAssertEqual(ProcessColumns.all(powerWindowHours: 2)
                        .first { $0.id == "window" }?.title, "2 hr power")
    }

    /// Only the name sorts alphabetically. A numeric column with a `stringValue`
    /// would sort "10" before "9".
    func testOnlyTheNameColumnSortsAsText() {
        for c in columns() {
            XCTAssertEqual(c.stringValue != nil, c.id == "name", c.id)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Honesty

final class ProcessCellHonestyTests: XCTestCase {

    /// nil renders as "—", never as 0. Each of these is a row where the quantity was
    /// not measured, and a zero would be a claim that it was.
    func testAnAbsentReadingIsADashAndNotAZero() {
        let bare = makeRow(system: makeAttributed(name: "WindowServer"))
        for id in ["window", "cost", "cpu", "memPct", "mem", "diskRead", "diskWrite",
                   "gpuPct", "gputime", "gpuPctHr"] {
            let (text, dim) = column(id).text(bare)
            XCTAssertEqual(text, "—", "\(id) invented a value for an unmeasured row")
            XCTAssertTrue(dim, "\(id) drew an absence at full strength")
        }
    }

    /// A row that only ever appeared in the GPU rollup has no measured CPU energy.
    /// Reporting 0.00 %/hr for it would be a measurement nobody made.
    func testAGPUOnlyRowHasNoBatteryRate() {
        let row = makeRow(gpu: makeAttributed(name: "com.apple.WindowServer", gpu_ms: 40))
        XCTAssertNil(row.pctHr)
        XCTAssertEqual(column("pctHr").text(row).text, "—")
    }

    /// A genuine zero is still a measurement and still prints. This is the other
    /// half of the rule: "—" must mean "not measured", not "small".
    func testAMeasuredZeroIsNotADash() {
        let row = makeRow(app: makeApp(name: "Idle", pctHr: 0, cpu: 0.4, disk: 0))
        XCTAssertEqual(column("pctHr").text(row).text, "<0.01")
        XCTAssertEqual(column("cpu").text(row).text, "0.4")
    }

    /// The other end of the same rule, and the end this table got wrong in five
    /// of its twelve columns. A process we SAMPLED and found doing nothing is a
    /// measured zero; only a row we could not sample at all is a "—". % CPU, Disk
    /// I/O and all three GPU columns printed the dash for both, which made an
    /// idle app indistinguishable from a coalition with no reading behind it.
    func testASampledButIdleReadingIsAZeroAndNotADash() {
        let idle = makeRow(app: makeApp(name: "Idle", cpu: 0, disk: 0),
                           gpu: makeAttributed(name: "Idle", pctHr: 0, gpu_ms: 0),
                           gpuTimeShare: 0)
        for id in ["cpu", "diskRead", "diskWrite", "gpuPct", "gputime", "gpuPctHr"] {
            let (text, dim) = column(id).text(idle)
            XCTAssertEqual(text, "0", "\(id) drew a measured zero as an absence")
            XCTAssertTrue(dim, "\(id) drew a zero at full strength")
        }
    }

    /// Below the column's resolution but still measured says so, in the same form
    /// %/hr and % Mem already use. Not "—", which would claim it was never read,
    /// and not a rounded "0.0", which would claim a precision it does not have.
    func testAReadingBelowTheColumnsResolutionSaysSoRatherThanVanishing() {
        let (text, dim) = column("cpu").text(makeRow(app: makeApp(name: "Quiet", cpu: 0.05)))
        XCTAssertEqual(text, "<0.1")
        XCTAssertTrue(dim)
    }

    /// A count of one is not drawn — the tooltip says as much, and a column of
    /// "1" down forty rows is width spent on nothing. A real count IS drawn, at
    /// full strength: it used to be dimmed unconditionally, so an app running
    /// thirty-seven helpers wore the same grey as the "—" beside it.
    func testARealProcessCountIsNotDimmedLikeAnAbsence() {
        let many = column("procs").text(makeRow(app: makeApp(name: "A", procs: 37)))
        XCTAssertEqual(many.text, "37")
        XCTAssertFalse(many.dim, "a real process count was drawn as an absence")
        let one = column("procs").text(makeRow(app: makeApp(name: "B", procs: 1)))
        XCTAssertEqual(one.text, "—")
        XCTAssertTrue(one.dim)
    }

    func testMemoryPercentIsOfInstalledRAM() {
        let row = makeRow(app: makeApp(name: "Big", memory: 4 * 1024 * 1024 * 1024),
                          totalMemory: 16 * 1024 * 1024 * 1024)
        XCTAssertEqual(row.memoryPercent ?? 0, 25, accuracy: 1e-9)
        XCTAssertEqual(column("memPct").text(row).text, "25.00")
    }

    /// The row-level modeled flag drives the name's colour, and it means "nothing
    /// here was measured per-process" — not "some column is apportioned". Every row
    /// has apportioned GPU columns; only these have no measured half at all.
    func testModeledMeansNoMeasuredProcessBehindTheRow() {
        XCTAssertTrue(makeRow(system: makeAttributed(name: "kernel_task")).isModeled)
        XCTAssertTrue(makeRow(gpu: makeAttributed(name: "WindowServer", gpu_ms: 9)).isModeled)
        XCTAssertFalse(makeRow(app: makeApp(name: "Safari"),
                               gpu: makeAttributed(name: "Safari", gpu_ms: 9)).isModeled,
                       "an app with an apportioned GPU share is still a measured row")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Sorting

final class ProcessSortTests: XCTestCase {

    /// Rows re-sort every couple of seconds, so ordering is read from the same
    /// `ProcessColumn` the cell was drawn from. A column that displayed one quantity
    /// and ordered by another would be undetectable at a glance and wrong every
    /// time.
    private func sorted(by id: String, ascending: Bool, _ rows: [Row]) -> [String] {
        var rows = rows
        let c = column(id)
        if let string = c.stringValue {
            rows.sort { a, b in
                let r = string(a).localizedCaseInsensitiveCompare(string(b)) == .orderedAscending
                return ascending ? r : !r
            }
            return rows.map(\.name)
        }
        rows.sort { a, b in
            switch (c.value(a), c.value(b)) {
            case let (x?, y?): return ascending ? x < y : x > y
            case (nil, _?):    return false
            case (_?, nil):    return true
            case (nil, nil):   return a.name.localizedCaseInsensitiveCompare(b.name)
                                    == .orderedAscending
            }
        }
        return rows.map(\.name)
    }

    /// One row per outcome: a large reading, a small one, a middling one, and a row
    /// that has no reading in this column at all — a coalition the GPU rollup named
    /// and rusage never saw.
    private var mixed: [Row] {
        [makeRow(app: makeApp(name: "Low", pctHr: 0.1, cpu: 1)),
         makeRow(app: makeApp(name: "High", pctHr: 9.0, cpu: 90)),
         makeRow(gpu: makeAttributed(name: "NoReading", gpu_ms: 5)),
         makeRow(app: makeApp(name: "Mid", pctHr: 1.0, cpu: 10))]
    }

    func testDescendingPutsTheLargestFirst() {
        XCTAssertEqual(sorted(by: "cpu", ascending: false, mixed).first, "High")
    }

    /// A row with no reading at all must sink in BOTH directions. Ascending, a nil
    /// treated as -1 would sort it above every real value, which is how "not
    /// measurable" ends up looking like the quietest process on the machine.
    func testAMissingReadingSinksWhicheverWayTheArrowPoints() {
        XCTAssertEqual(sorted(by: "cpu", ascending: false, mixed).last, "NoReading")
        XCTAssertEqual(sorted(by: "cpu", ascending: true, mixed).last, "NoReading")
    }

    func testTheNameColumnSortsAlphabeticallyAndCaseInsensitively() {
        let rows = [makeRow(app: makeApp(name: "zed")),
                    makeRow(app: makeApp(name: "Alpha")),
                    makeRow(app: makeApp(name: "beta"))]
        XCTAssertEqual(sorted(by: "name", ascending: true, rows), ["Alpha", "beta", "zed"])
        XCTAssertEqual(sorted(by: "name", ascending: false, rows), ["zed", "beta", "Alpha"])
    }

    /// The table's default. Sorting by anything else on launch would answer a
    /// question nobody asked.
    func testTheDefaultSortIsAColumnThatExists() {
        XCTAssertNotNil(ProcessColumns.byID(10)[ProcessColumns.defaultSortKey])
    }

    /// Every column's sort descriptor prototype is its own identifier, so a header
    /// click resolves back to the definition it came from. A column whose value
    /// closure always returns nil could never be ordered at all.
    func testEveryNumericColumnCanActuallyOrderSomething() {
        let a = makeRow(app: makeApp(name: "A", pctHr: 1, procs: 3, cpu: 5,
                                     memory: 1024, disk: 10),
                        gpu: makeAttributed(name: "A", pctHr: 2, gpu_ms: 50),
                        gpuTimeShare: 0.5, windowPct: 1.5, costMin: 30)
        for c in columns() where c.stringValue == nil {
            XCTAssertNotNil(c.value(a), "\(c.id) cannot order a fully populated row")
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: Joining the three sources

final class ProcessRowBuilderTests: XCTestCase {

    private func build(apps: [AppDrain] = [],
                       system: [SystemAttribution.Row] = [],
                       gpu: [SystemAttribution.Row] = [],
                       window: [String: Double] = [:]) -> [Row] {
        ProcessRowBuilder.rows(apps: apps, systemApps: system, gpuApps: gpu,
                               windowPercents: window,
                               runtimeCost: { _ in nil },
                               totalMemoryBytes: 16 * 1024 * 1024 * 1024)
    }

    /// The whole point of one table: an app burning CPU and holding the GPU is ONE
    /// row carrying both, not two rows in two tabs that nothing connects.
    func testAMeasuredAppAbsorbsItsGPUShare() {
        let rows = build(apps: [makeApp(name: "Safari", bundleID: "com.apple.safari")],
                         gpu: [makeAttributed(name: "Safari", bundleID: "com.apple.safari",
                                              gpu_ms: 400)])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].gpu?.gpu_ms, 400)
        XCTAssertNotNil(rows[0].app, "the measured half was lost in the join")
    }

    /// Daemons have no bundle at all, so a bundle-only join would list them twice.
    func testTheJoinFallsBackToTheNameWhenThereIsNoBundle() {
        let rows = build(apps: [makeApp(name: "mediaanalysisd", isApp: false)],
                         gpu: [makeAttributed(name: "mediaanalysisd", gpu_ms: 12)])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].gpu?.gpu_ms, 12)
    }

    /// One coalition's GPU time can only be spent once. Two apps resolving to the
    /// same name would otherwise each be credited with the whole of it, and the
    /// column would sum to more GPU than the machine has.
    func testAGPURowIsClaimedByOnlyOneApp() {
        let rows = build(apps: [makeApp(name: "Helper"), makeApp(name: "Helper")],
                         gpu: [makeAttributed(name: "Helper", gpu_ms: 90)])
        XCTAssertEqual(rows.compactMap { $0.gpu?.gpu_ms }, [90])
    }

    /// WindowServer is the largest named consumer on the machine and has no pids
    /// this app can read. A join that only kept matched rows would hide it.
    func testACoalitionWithNoMeasuredAppStillGetsARow() {
        let rows = build(gpu: [makeAttributed(name: "WindowServer", gpu_ms: 900)])
        XCTAssertEqual(rows.map(\.name), ["WindowServer"])
        XCTAssertTrue(rows[0].isModeled)
    }

    func testGPUShareIsAFractionOfAllAttributedGPUTime() {
        let rows = build(gpu: [makeAttributed(name: "A", gpu_ms: 300),
                               makeAttributed(name: "B", gpu_ms: 100)])
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0) })
        XCTAssertEqual(byName["A"]?.gpuTimeShare ?? 0, 0.75, accuracy: 1e-9)
        XCTAssertEqual(byName["B"]?.gpuTimeShare ?? 0, 0.25, accuracy: 1e-9)
    }

    /// The share is divided on the SAME quantity the watts were: the current GPU
    /// rate, not the hour's accumulated GPU time.
    ///
    /// The two disagree exactly when it matters — a coalition that hammered the
    /// GPU an hour ago and stopped still owns most of `gpu_ms` while owning none
    /// of the rail right now. Taking the share from the hour totals put GPU % and
    /// GPU %/hr side by side in one row describing the same thing and disagreeing
    /// by an order of magnitude.
    func testGPUShareFollowsTheRateTheWattsWereDividedOn() {
        // A did the work an hour ago (900 of the 1000 ms) and has stopped; B is
        // the one on the GPU now.
        let rows = build(gpu: [makeAttributed(name: "A", gpu_ms: 900, gpuRate: 1),
                               makeAttributed(name: "B", gpu_ms: 100, gpuRate: 9)])
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0) })
        XCTAssertEqual(byName["B"]?.gpuTimeShare ?? 0, 0.9, accuracy: 1e-9,
                       "the share came from the hour total, not the rate")
        XCTAssertEqual(byName["A"]?.gpuTimeShare ?? 0, 0.1, accuracy: 1e-9)
    }

    /// Nothing is using the GPU right now, so "this row's share of it" has no
    /// answer. That is a "—", and it must not become a zero — nor a share taken
    /// from an hour of history the watts were not divided on.
    func testNoCurrentGPUActivityLeavesTheShareUnanswered() {
        let rows = build(gpu: [makeAttributed(name: "A", gpu_ms: 900, gpuRate: 0),
                               makeAttributed(name: "B", gpu_ms: 100, gpuRate: 0)])
        for r in rows {
            XCTAssertNil(r.gpuTimeShare, "\(r.name) invented a share of no activity")
            XCTAssertEqual(column("gpuPct").text(r).text, "—")
        }
    }

    // ── Which rows earn a place ─────────────────────────────────────────────

    /// An open app that is doing nothing is an answer. Dropping it makes it blink
    /// out of the table and back, which reads as a bug.
    func testAnApplicationIsAlwaysListed() {
        let idle = makeRow(app: makeApp(name: "TextEdit", pctHr: 0, cpu: 0, memory: 1024))
        XCTAssertTrue(ProcessRowBuilder.isNotable(idle, floor_pctHr: 0.01))
    }

    /// The old Memory lens admitted anything with a footprint above zero — which is
    /// every process on the machine. In a table that shows every column at once that
    /// is ~220 rows of idle daemons.
    func testAnIdleDaemonNeedsMoreThanAFootprintToEarnARow() {
        let small = makeRow(app: makeApp(name: "quietd", isApp: false, pctHr: 0,
                                         cpu: 0, memory: 4 * 1024 * 1024))
        XCTAssertFalse(ProcessRowBuilder.isNotable(small, floor_pctHr: 0.01))

        let large = makeRow(app: makeApp(name: "fatd", isApp: false, pctHr: 0, cpu: 0,
                                         memory: ProcessRowBuilder.notableMemoryBytes))
        XCTAssertTrue(ProcessRowBuilder.isNotable(large, floor_pctHr: 0.01),
                      "a daemon holding 128 MB is worth a row")
    }

    func testADaemonEarnsARowByAnyOneOfItsColumns() {
        func daemon(cpu: Double = 0, disk: Double = 0, pctHr: Double = 0,
                    gpu_ms: UInt64 = 0) -> Row {
            makeRow(app: makeApp(name: "d", isApp: false, pctHr: pctHr, cpu: cpu,
                                 memory: 1024, disk: disk),
                    gpu: gpu_ms > 0 ? makeAttributed(name: "d", gpu_ms: gpu_ms) : nil)
        }
        XCTAssertTrue(ProcessRowBuilder.isNotable(daemon(cpu: 2.0), floor_pctHr: 0.01))
        XCTAssertTrue(ProcessRowBuilder.isNotable(daemon(disk: 1), floor_pctHr: 0.01))
        XCTAssertTrue(ProcessRowBuilder.isNotable(daemon(pctHr: 0.5), floor_pctHr: 0.01))
        XCTAssertTrue(ProcessRowBuilder.isNotable(daemon(gpu_ms: 1), floor_pctHr: 0.01))
        XCTAssertFalse(ProcessRowBuilder.isNotable(daemon(), floor_pctHr: 0.01))
    }
}
