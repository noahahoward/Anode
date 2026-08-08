import XCTest
@testable import PowerKit

/// The apportionment has one job that matters: divide a MEASURED bucket among
/// names without changing its size. Every test here is ultimately about that —
/// a row set that sums to more than the bucket has invented energy, and a row
/// set that silently sums to less has hidden some.
final class SystemAttributionTests: XCTestCase {

    private let scale = BatteryScale(fullChargeCapacity_mAh: 6197,
                                     designCapacity_mAh: 6249,
                                     nominalVoltage_V: 11.58,
                                     isCalibrated: false)

    /// Pads a fixture past `minimumCoalitions`. Zero-weight entries take no
    /// share, so they change no expected value — they only make the sample large
    /// enough to count as a valid observation of the machine.
    private func padded(_ rows: [CoalitionUsage]) -> [CoalitionUsage] {
        rows + (0..<SystemAttribution.minimumCoalitions).map {
            usage("pad.\($0)", cpu: 0, gpu: 0)
        }
    }

    /// Mirrors how the real rollup names a coalition: the last reverse-DNS
    /// component of the bundle id. Using the raw id as the display name here
    /// would make the name-exclusion tests pass without exercising the match.
    private func usage(_ id: String, cpu: UInt64, gpu: UInt64 = 0,
                       system: Bool = true) -> CoalitionUsage {
        CoalitionUsage(bundleID: id,
                       displayName: id.contains(".")
                           ? String(id.split(separator: ".").last!) : id,
                       cpu_ms: cpu, gpu_ms: gpu,
                       energyShare: 0, isSystem: system)
    }

    func testRowsPartitionTheBucketRatherThanAddingToIt() {
        let rows = SystemAttribution.apportion(
            watts: 10,
            among: padded([usage("a", cpu: 600), usage("b", cpu: 400)]),
            by: .cpuTime, excluding: .none, scale: scale)

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.watts }, 10, accuracy: 1e-9)
        XCTAssertEqual(rows[0].watts, 6, accuracy: 1e-9)
        XCTAssertEqual(rows[1].watts, 4, accuracy: 1e-9)
    }

    /// Double counting is the failure mode that would silently inflate the whole
    /// ledger: an app rusage already measured must not also take a slice of the
    /// remainder that exists precisely because rusage could NOT see it.
    func testAlreadyAttributedAppsAreExcludedEntirely() {
        let rows = SystemAttribution.apportion(
            watts: 10,
            among: padded([usage("seen", cpu: 900), usage("unseen", cpu: 100)]),
            by: .cpuTime,
            excluding: .init(bundleIDs: ["seen"], names: []), scale: scale)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].bundleID, "unseen")
        // The excluded coalition's weight leaves with it: the one surviving row
        // takes the whole bucket, not 10% of it.
        XCTAssertEqual(rows[0].watts, 10, accuracy: 1e-9)
    }

    /// CPU watts divided by GPU time (or vice versa) would misattribute in
    /// proportion to how lopsided an app is — the exact reason this does not use
    /// Apple's blended energy score as the weight.
    func testWeightSelectsTheMatchingCounter() {
        let all = padded([usage("cpuHeavy", cpu: 1000, gpu: 0),
                          usage("gpuHeavy", cpu: 0, gpu: 1000)])

        let byCPU = SystemAttribution.apportion(watts: 8, among: all, by: .cpuTime,
                                                excluding: .none, scale: scale)
        XCTAssertEqual(byCPU.count, 1)
        XCTAssertEqual(byCPU[0].bundleID, "cpuHeavy")

        let byGPU = SystemAttribution.apportion(watts: 8, among: all, by: .gpuTime,
                                                excluding: .none, scale: scale)
        XCTAssertEqual(byGPU.count, 1)
        XCTAssertEqual(byGPU[0].bundleID, "gpuHeavy")
    }

    /// Rows below the threshold are dropped WITHOUT their weight being
    /// redistributed, so the visible rows sum to less than the bucket. That
    /// shortfall staying anonymous is the intended behaviour — inflating the
    /// survivors to close the gap is the redistribution this app exists to avoid.
    func testSubThresholdRowsAreDroppedNotRedistributed() {
        var all = [usage("big", cpu: 900)]
        for i in 0..<20 { all.append(usage("tiny\(i)", cpu: 5)) }
        // Already well over the coverage gate.

        let rows = SystemAttribution.apportion(
            watts: 10, among: all, by: .cpuTime, excluding: .none,
            scale: scale, minimumShare: 0.01)

        XCTAssertEqual(rows.count, 1, "only the big coalition clears 1%")
        let total = rows.reduce(0) { $0 + $1.watts }
        XCTAssertLessThan(total, 10, "dropped weight must not be handed to survivors")
        XCTAssertEqual(total, 10 * (900.0 / 1000.0), accuracy: 1e-9)
    }

    /// The bug this caught in the live table: `contactsd` was measured at
    /// 0.03 %/hr and simultaneously handed a modeled 0.04 %/hr share, appearing
    /// twice. Daemons live outside any bundle, so AppIdentity.bundleID is nil for
    /// them and id-only exclusion lets through exactly the population that
    /// overlaps most.
    func testDaemonsAreExcludedByNameWhenTheyHaveNoBundleID() {
        let all = padded([usage("com.apple.contactsd", cpu: 500),
                          usage("com.apple.WindowServer", cpu: 500)])

        // What the app can actually offer for a daemon: a name, no bundle id.
        let rows = SystemAttribution.apportion(
            watts: 10, among: all, by: .cpuTime,
            excluding: .init(bundleIDs: [], names: ["contactsd"]), scale: scale)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].name, "WindowServer")
    }

    func testNameExclusionIgnoresCase() {
        let rows = SystemAttribution.apportion(
            watts: 10, among: padded([usage("com.apple.WindowServer", cpu: 100)]),
            by: .cpuTime,
            excluding: .init(bundleIDs: [], names: ["windowserver"]), scale: scale)
        XCTAssertTrue(rows.isEmpty, "the two sources capitalise names differently")
    }

    func testNoBucketOrNoDataYieldsNoRows() {
        XCTAssertTrue(SystemAttribution.apportion(
            watts: 0, among: padded([usage("a", cpu: 100)]),
            by: .cpuTime, excluding: .none, scale: scale).isEmpty)

        XCTAssertTrue(SystemAttribution.apportion(
            watts: 10, among: [], by: .cpuTime, excluding: .none, scale: scale).isEmpty)

        // Coalitions that existed but burned no time of the relevant kind cannot
        // be given a share of anything — dividing by a zero total would produce
        // NaN watts and poison every downstream sum.
        XCTAssertTrue(SystemAttribution.apportion(
            watts: 10, among: padded([usage("idle", cpu: 0, gpu: 0)]),
            by: .cpuTime, excluding: .none, scale: scale).isEmpty)
    }

    /// A rollup that saw only a handful of coalitions cannot divide a
    /// machine-wide bucket. The survivors would still sum to 100% of it and look
    /// exactly as authoritative as a good sample. Observed live: a 15 minute
    /// window returned 3 coalitions and gave Plexamp 52% of all system-process
    /// power, while WindowServer — which was using more — appeared nowhere.
    func testTooFewCoalitionsSuppressesAllRowsRatherThanApportioning() {
        let thin = (0..<(SystemAttribution.minimumCoalitions - 1)).map {
            usage("app.\($0)", cpu: 100)
        }
        XCTAssertTrue(SystemAttribution.apportion(
            watts: 10, among: thin, by: .cpuTime,
            excluding: .none, scale: scale).isEmpty)

        // One more coalition clears the gate and the rows appear.
        let enough = thin + [usage("app.extra", cpu: 100)]
        XCTAssertFalse(SystemAttribution.apportion(
            watts: 10, among: enough, by: .cpuTime,
            excluding: .none, scale: scale).isEmpty)
    }

    func testPercentPerHourTracksWattsThroughTheBatteryScale() {
        let rows = SystemAttribution.apportion(
            watts: 5, among: padded([usage("only", cpu: 100)]),
            by: .cpuTime, excluding: .none, scale: scale)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].percentPerHour,
                       3600 * 5 / scale.joulesPerPercent, accuracy: 1e-9)
    }

    func testEveryRowIsMarkedModeled() {
        let rows = SystemAttribution.apportion(
            watts: 5, among: padded([usage("a", cpu: 50), usage("b", cpu: 50)]),
            by: .cpuTime, excluding: .none, scale: scale)
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.isModeled },
                      "an apportioned row must never present as measured")
    }

    // ── The living filter, and how it deleted the biggest consumer ──────────
    //
    // The filter exists so a quit app cannot draw present-tense power from an
    // hour-old rollup. It was built on `proc_name`, which EPERMs for processes
    // owned by another user, so it saw 340 of ~700 processes and judged every
    // root daemon dead. Measured consequence: WindowServer, with 6,295 ms of CPU
    // in the hour — 40x the largest surviving row — was struck from the ledger
    // and its measured watts redistributed across trivial user daemons. That is
    // how a Batteries widget which used 17 ms in an hour reached the top of the
    // battery list.
    //
    // Names now come from `sysctl KERN_PROC_ALL`, which needs no privilege and
    // returned 513 processes on the same machine. The catch is `p_comm`, which
    // is truncated to 16 characters, so matching must be prefix-aware.

    func testALongNamedCoalitionSurvivesATruncatedProcessName() {
        // What the kernel actually reports for this process.
        let running: Set<String> = ["batteriesavocado"]
        XCTAssertTrue(ProcessSampler.nameMatches("BatteriesAvocadoWidgetExtension", in: running))
    }

    func testAShortNameStillRequiresAnExactMatch() {
        // `secd` must not be matched alive by `secdiagnosticd` running: only
        // names long enough to have BEEN truncated may match as a prefix.
        XCTAssertFalse(ProcessSampler.nameMatches("secd", in: ["secdiagnosticd"]))
        XCTAssertTrue(ProcessSampler.nameMatches("secd", in: ["secd"]))
    }

    func testMatchingIsCaseInsensitiveBothWays() {
        XCTAssertTrue(ProcessSampler.nameMatches("WindowServer", in: ["windowserver"]))
    }

    /// The regression itself, at the level that matters: a live daemon with the
    /// dominant CPU time must keep its share instead of donating it.
    func testALiveDaemonIsNotStruckFromTheLedger() {
        let all = padded([usage("com.apple.WindowServer", cpu: 6295),
                          usage("com.apple.Batteries.BatteriesAvocadoWidgetExtension", cpu: 17)])
        let living: Set<String> = ["windowserver", "batteriesavocado"]

        let rows = SystemAttribution.apportion(
            watts: 10, among: all, by: .cpuTime,
            excluding: .none, living: living, scale: scale)

        let ws = rows.first { $0.name == "WindowServer" }
        XCTAssertNotNil(ws, "the largest consumer must not be filtered out")
        XCTAssertEqual(ws?.watts ?? 0, 10 * 6295.0 / 6312.0, accuracy: 1e-6)
        // And the trivial one keeps only what its 17 ms can justify.
        let avo = rows.first { $0.name.hasPrefix("Batteries") }
        XCTAssertLessThan(avo?.watts ?? 0, 0.05)
    }

    /// Without the daemon present, the trivial row inherits everything — this is
    /// the exact shape of the bug, pinned so it cannot come back.
    func testStrikingTheDaemonHandsItsPowerToTheTrivialRow() {
        let all = padded([usage("com.apple.WindowServer", cpu: 6295),
                          usage("com.apple.Batteries.BatteriesAvocadoWidgetExtension", cpu: 17)])
        let rows = SystemAttribution.apportion(
            watts: 10, among: all, by: .cpuTime,
            excluding: .none, living: ["batteriesavocado"], scale: scale)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].watts, 10, accuracy: 1e-9,
                       "17 ms of CPU taking the entire measured bucket is the bug")
    }

    /// An empty set means the caller could not enumerate at all, and the filter
    /// must be skipped rather than deleting every row.
    func testAnEmptyLivingSetDisablesTheFilter() {
        let all = padded([usage("com.apple.WindowServer", cpu: 6295)])
        let rows = SystemAttribution.apportion(
            watts: 10, among: all, by: .cpuTime,
            excluding: .none, living: [], scale: scale)
        XCTAssertEqual(rows.count, 1)
    }

    /// The enumeration itself, against the live machine. Root-owned daemons are
    /// the whole population this had to reach.
    func testEnumerationSeesProcessesThisUserDoesNotOwn() throws {
        let running = Set(ProcessSampler.runningNames().map { $0.lowercased() })
        try XCTSkipIf(running.isEmpty, "cannot enumerate processes here")
        XCTAssertTrue(running.contains("windowserver"),
                      "root-owned daemons must be visible; got \(running.count) names")
    }
}
