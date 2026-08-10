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
                     disk: Double = 0) -> AppDrain {
    AppDrain(identity: AppIdentity(name: name, bundlePath: nil,
                                   bundleID: bundleID, isApp: isApp),
             joules: watts * 2,
             watts: watts,
             percentPerHour: pctHr,
             processCount: procs,
             pids: Array(1...max(1, procs)).map { pid_t($0) },
             cpuPercent: cpu,
             memoryBytes: memory,
             diskBytesPerSec: disk)
}

private func makeAttributed(name: String, bundleID: String = "",
                            pctHr: Double = 0.5,
                            gpu_ms: UInt64 = 0,
                            isSystem: Bool = true) -> SystemAttribution.Row {
    SystemAttribution.Row(bundleID: bundleID, name: name, watts: 0.3,
                          percentPerHour: pctHr, cpu_ms: 100, gpu_ms: gpu_ms,
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
                        "memPct", "mem", "disk", "gpuPct", "gputime", "gpuPctHr"])
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
        for id in ["window", "cost", "cpu", "memPct", "mem", "disk",
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
