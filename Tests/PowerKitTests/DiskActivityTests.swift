import XCTest
@testable import PowerKit

/// Disk is the one row in the sidebar that shows a rate where its neighbours show
/// a utilisation, and that is a deliberate decision these tests exist to protect.
///
/// `IOBlockStorageDriver` publishes `Total Time (Read)`/`Total Time (Write)`
/// alongside the byte counts, which looks like the makings of a percentage. It is
/// not one: the timer sums the residency of requests that overlap in the NVMe
/// queue, so it scales with queue depth rather than with load. Measured on this
/// machine (Mac17,9, APPLE SSD AP1024Z) reading one file with `F_NOCACHE`:
/// 74% of "busy time" at one thread and 868 MB/s, against 1394% and 5355 MB/s at
/// sixteen. A number that reaches 1394% has no 100% in it, and the low reading is
/// the one where the disk was doing least.
///
/// So `testDiskMetricsAreThroughputAndNeverAPercentage` is the load-bearing test
/// in this file: it fails the moment anyone reintroduces a disk percentage.
final class DiskActivityTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func counters(_ pairs: [UInt64: (UInt64, UInt64)]) -> [UInt64: DiskActivity.Counters] {
        pairs.mapValues { DiskActivity.Counters(bytesRead: $0.0, bytesWritten: $0.1) }
    }

    // ── The decision itself ───────────────────────────────────────────────────

    /// Every registered disk metric must be a throughput. If a future change adds
    /// a `.percent` or `.ratio` disk metric it is claiming a denominator that was
    /// measured not to exist, and this fails.
    func testDiskMetricsAreThroughputAndNeverAPercentage() {
        let r = MetricRegistry()
        r.registerSystemMetrics()
        let disk = r.descriptors().filter { $0.category == "Disk" }

        XCTAssertEqual(Set(disk.map(\.id.rawValue)),
                       [MetricID.diskActivity.rawValue,
                        MetricID.diskRead.rawValue,
                        MetricID.diskWrite.rawValue])
        for d in disk {
            XCTAssertEqual(d.unit, .bytesPerSecond,
                           "\(d.id.rawValue) must be a rate: no honest disk percentage exists")
        }
    }

    /// The sidebar shows one string for both directions. Both halves must come from
    /// `MetricUnit.bytesPerSecond` so the row can never spell a rate differently
    /// from the menu bar widget showing the same number.
    func testDiskActivityTextIsReadSlashWriteFromTheSharedFormatter() {
        let r = MetricRegistry()
        r.registerSystemMetrics()
        r.update(system: snapshot(read: 1_572_864, written: 348_160))   // 1.5 MB/s, 340 KB/s

        let v = try! XCTUnwrap(r.value(for: .diskActivity))
        XCTAssertEqual(v.text, "1.5MB/s/340KB/s")
        XCTAssertEqual(v.text,
                       MetricUnit.bytesPerSecond.format(1_572_864) + "/"
                       + MetricUnit.bytesPerSecond.format(348_160))
        XCTAssertEqual(v.value, 1_572_864 + 348_160, accuracy: 0.001)
        XCTAssertFalse(v.isEstimate, "these are counter deltas, not a model")
    }

    /// A machine that has not sampled the disk yet shows "—", not 0 B/s. A skipped
    /// subsystem must not read as a silent one.
    func testDiskMetricsAreNilBeforeTheFirstSample() {
        let r = MetricRegistry()
        r.registerSystemMetrics()
        XCTAssertNil(r.value(for: .diskActivity))
        XCTAssertNil(r.value(for: .diskRead))
        XCTAssertNil(r.value(for: .diskWrite))

        r.update(system: snapshot(read: nil, written: nil))
        XCTAssertNil(r.value(for: .diskActivity), "a tick that did not sample disk says nothing")
        XCTAssertNil(r.value(for: .diskRead))
        XCTAssertNil(r.value(for: .diskWrite))
    }

    // ── Rates from synthetic deltas ───────────────────────────────────────────

    func testFirstReadHasNoIntervalToAverageOver() {
        let d = DiskActivity()
        XCTAssertNil(d.sample(counters: counters([1: (1_000, 2_000)]), at: t0))
    }

    func testRateIsTheByteDeltaOverTheInterval() {
        let d = DiskActivity()
        _ = d.sample(counters: counters([1: (1_000, 2_000)]), at: t0)

        let s = try! XCTUnwrap(d.sample(counters: counters([1: (1_000 + 8_000, 2_000 + 500)]),
                                        at: t0 + 4))
        XCTAssertEqual(s.bytesReadPerSec, 2_000, accuracy: 0.001)
        XCTAssertEqual(s.bytesWrittenPerSec, 125, accuracy: 0.001)
        XCTAssertEqual(s.totalPerSec, 2_125, accuracy: 0.001)
        XCTAssertEqual(s.interval, 4, accuracy: 0.001)
    }

    /// Counters far past 2^32 — the boot disk was already at 1.3 TB read when this
    /// was written, so nothing in the path may narrow to 32 bits.
    func testCountersFarAboveThe32BitRangeAreNotTruncated() {
        let d = DiskActivity()
        let base = UInt64(UInt32.max) * 400 + 12_345          // ~1.7 TB
        _ = d.sample(counters: counters([1: (base, base)]), at: t0)

        let s = try! XCTUnwrap(d.sample(
            counters: counters([1: (base + 6_000_000, base + 2_000_000)]), at: t0 + 2))
        XCTAssertEqual(s.bytesReadPerSec, 3_000_000, accuracy: 0.001)
        XCTAssertEqual(s.bytesWrittenPerSec, 1_000_000, accuracy: 0.001)
    }

    func testDevicesAreSummedIntoTheWholeMachineFigure() {
        let d = DiskActivity()
        _ = d.sample(counters: counters([1: (0, 0), 2: (0, 0)]), at: t0)

        let s = try! XCTUnwrap(d.sample(counters: counters([1: (100, 10), 2: (400, 90)]),
                                        at: t0 + 1))
        XCTAssertEqual(s.bytesReadPerSec, 500, accuracy: 0.001)
        XCTAssertEqual(s.bytesWrittenPerSec, 100, accuracy: 0.001)
    }

    // ── Resets, gaps and bounds ───────────────────────────────────────────────

    /// A counter that goes backwards is a device that was torn down and recreated,
    /// never a wrap: at 64 bits these do not wrap in any human timescale. Wrapping
    /// arithmetic (`&-`) would turn a reset into an ~18 exabyte delta, so the
    /// device is dropped for the tick instead and re-baselined for the next one.
    func testCounterResetDropsThatDeviceInsteadOfReportingAnExabyte() {
        let d = DiskActivity()
        _ = d.sample(counters: counters([1: (5_000_000_000, 900), 2: (0, 0)]), at: t0)

        // Device 1 reset to near zero; device 2 genuinely moved 300 B.
        let s = try! XCTUnwrap(d.sample(counters: counters([1: (128, 0), 2: (300, 0)]),
                                        at: t0 + 1))
        XCTAssertEqual(s.bytesReadPerSec, 300, accuracy: 0.001,
                       "only the surviving device may contribute")
        XCTAssertEqual(s.bytesWrittenPerSec, 0, accuracy: 0.001)

        // And the reset device is usable again from its new baseline.
        let next = try! XCTUnwrap(d.sample(counters: counters([1: (1_128, 0), 2: (300, 0)]),
                                           at: t0 + 2))
        XCTAssertEqual(next.bytesReadPerSec, 1_000, accuracy: 0.001)
    }

    /// The reset must not be laundered into a zero either. With nothing else to
    /// report, the honest answer is "no reading", which renders as "—".
    func testLoneResetDeviceYieldsNilRatherThanZero() {
        let d = DiskActivity()
        _ = d.sample(counters: counters([1: (5_000_000_000, 900)]), at: t0)
        XCTAssertNil(d.sample(counters: counters([1: (128, 0)]), at: t0 + 1))
    }

    /// The case that proves the decrease check is load-bearing rather than a
    /// restatement of the plausibility bound.
    ///
    /// For an ordinary reset the two agree by accident: `&-` on a counter that
    /// dropped from 5 GB to nothing yields ~1.8e19 B/s, which the bound rejects
    /// anyway. Start the counter near `UInt64.max` instead and the wrap lands back
    /// in believable territory — `0 &- (UInt64.max - 1000)` is 1001, a serene
    /// 1 kB/s that no bound would ever question. Wrapping arithmetic would publish
    /// it as a measurement. Dropping the device reports nothing, which is true.
    func testWrapWouldFabricateAPlausibleRateSoDecreasesAreDroppedInstead() {
        let d = DiskActivity()
        let nearMax = UInt64.max - 1_000
        _ = d.sample(counters: counters([1: (nearMax, nearMax)]), at: t0)

        XCTAssertNil(d.sample(counters: counters([1: (0, 0)]), at: t0 + 1),
                     "a wrapped delta of 1001 B/s is plausible and still fiction")

        // The same reset alongside a healthy device: only the healthy one counts.
        let d2 = DiskActivity()
        _ = d2.sample(counters: counters([1: (nearMax, nearMax), 2: (0, 0)]), at: t0)
        let s = try! XCTUnwrap(d2.sample(counters: counters([1: (0, 0), 2: (640, 0)]), at: t0 + 1))
        XCTAssertEqual(s.bytesReadPerSec, 640, accuracy: 0.001)
        XCTAssertEqual(s.bytesWrittenPerSec, 0, accuracy: 0.001)
    }

    /// The plausibility bound DROPS the offending device rather than clamping it to
    /// the ceiling. A clamp would print 64 GB/s — a plausible-looking headline
    /// number manufactured out of a counter doing something we do not understand.
    func testImplausibleRateDropsTheDeviceRatherThanClampingIt() {
        let d = DiskActivity()
        _ = d.sample(counters: counters([1: (0, 0), 2: (0, 0)]), at: t0)

        let absurd = UInt64(DiskActivity.maxPlausibleBytesPerSec * 2)   // 128 GB/s
        let s = try! XCTUnwrap(d.sample(counters: counters([1: (absurd, 0), 2: (700, 0)]),
                                        at: t0 + 1))
        XCTAssertEqual(s.bytesReadPerSec, 700, accuracy: 0.001)
        XCTAssertLessThanOrEqual(s.bytesReadPerSec, DiskActivity.maxPlausibleBytesPerSec)
    }

    /// A device seen for the first time has no baseline, so it contributes nothing.
    /// With every device new there is no interval to speak about at all.
    func testDeviceWithNoBaselineContributesNothingAndAloneYieldsNil() {
        let d = DiskActivity()
        _ = d.sample(counters: counters([1: (0, 0)]), at: t0)

        // Device 1 vanished, device 9 just appeared: nothing can be said.
        XCTAssertNil(d.sample(counters: counters([9: (1_000, 1_000)]), at: t0 + 1))

        // Device 9 now has a baseline and reports on its own.
        let s = try! XCTUnwrap(d.sample(counters: counters([9: (3_000, 1_000)]), at: t0 + 2))
        XCTAssertEqual(s.bytesReadPerSec, 2_000, accuracy: 0.001)
    }

    func testEmptyCounterSetIsNilNotZero() {
        let d = DiskActivity()
        XCTAssertNil(d.sample(counters: [:], at: t0))
        XCTAssertNil(d.sample(counters: [:], at: t0 + 1))
    }

    /// Two reads inside the same tick would divide a tiny delta by a tiny interval
    /// and print noise as a headline rate.
    func testIntervalTooShortToDivideByIsRejected() {
        let d = DiskActivity()
        _ = d.sample(counters: counters([1: (0, 0)]), at: t0)
        XCTAssertNil(d.sample(counters: counters([1: (1_000_000, 0)]), at: t0 + 0.01))
    }

    // ── Live hardware ─────────────────────────────────────────────────────────

    /// The counters exist and can be read unprivileged on this machine.
    func testLiveCountersAreReadableAndNonEmpty() throws {
        let d = DiskActivity()
        let c = try XCTUnwrap(d.readCounters(), "no IOBlockStorageDriver exposed Statistics")
        XCTAssertFalse(c.isEmpty)
    }

    /// The live read must not narrow anywhere. `Statistics` is published as 64-bit
    /// and the boot disk here had already served 1.3 TB, so a 32-bit path would
    /// lop off the top and print a rate computed from the low word — the exact bug
    /// the network counters had. Skipped rather than failed on a machine that has
    /// genuinely not moved 4 GB since boot, because there the claim is untestable
    /// rather than false.
    func testLiveCountersAreNotNarrowedTo32Bits() throws {
        let d = DiskActivity()
        let c = try XCTUnwrap(d.readCounters())
        let widest = c.values.map { max($0.bytesRead, $0.bytesWritten) }.max() ?? 0
        // The skip is decided by uptime ALONE. Gating it on the counter itself would
        // let a truncating bug silence the very test meant to catch it — the
        // narrowed value would fall under 4 GB and the test would skip, not fail.
        try XCTSkipUnless(ProcessInfo.processInfo.systemUptime > 600,
                          "freshly booted: 4 GB of cumulative I/O not yet guaranteed")
        XCTAssertGreaterThan(widest, UInt64(UInt32.max),
                             "counter looks truncated to 32 bits")
    }

    /// Disk images are excluded, because every byte they serve is also a byte the
    /// SSD beneath them served and counting both double-counts the same I/O. This
    /// machine mounts four `AppleDiskImageDevice` cryptexes behind one SSD, so the
    /// physical set must be strictly smaller than the set of all drivers.
    func testDiskImagesAreExcludedFromThePhysicalSet() throws {
        let d = DiskActivity()
        let physical = try XCTUnwrap(d.readCounters())

        var all = 0
        var iterator: io_iterator_t = 0
        let match = try XCTUnwrap(IOServiceMatching("IOBlockStorageDriver"))
        XCTAssertEqual(IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator),
                       KERN_SUCCESS)
        while case let s = IOIteratorNext(iterator), s != 0 { all += 1; IOObjectRelease(s) }
        IOObjectRelease(iterator)

        XCTAssertGreaterThan(all, physical.count,
                             "expected virtual disk-image drivers to be filtered out")
    }

    /// End to end against the real registry: a live sample either produces a
    /// finite, bounded reading or nothing at all — never a NaN and never a number
    /// above what the hardware can do.
    func testLiveSampleIsFiniteAndWithinThePlausibilityBound() throws {
        let d = DiskActivity()
        XCTAssertNil(d.sample(), "first live read has no interval")
        Thread.sleep(forTimeInterval: 0.3)

        let s = try XCTUnwrap(d.sample())
        XCTAssertTrue(s.bytesReadPerSec.isFinite)
        XCTAssertTrue(s.bytesWrittenPerSec.isFinite)
        XCTAssertGreaterThanOrEqual(s.bytesReadPerSec, 0)
        XCTAssertGreaterThanOrEqual(s.bytesWrittenPerSec, 0)
        XCTAssertLessThanOrEqual(s.bytesReadPerSec, DiskActivity.maxPlausibleBytesPerSec)
        XCTAssertLessThanOrEqual(s.bytesWrittenPerSec, DiskActivity.maxPlausibleBytesPerSec)
    }

    // ── Gating ────────────────────────────────────────────────────────────────

    /// The app must not pay for a subsystem nobody is showing, and a skipped one
    /// must report nothing rather than a stale or zero reading.
    func testDiskIsSkippedWhenNotNeededAndSampledWhenItIs() {
        let m = SystemMetrics()
        XCTAssertTrue(SystemMetrics.Needs.all.contains(.disk))

        // Prime it first. A disk sampler with no baseline returns nil whether or not
        // it was asked to run, so testing the gate on a cold sampler proves nothing:
        // the interesting state is one that COULD report and must not.
        _ = m.sample(needs: [.disk])
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertNotNil(m.sample(needs: [.disk]).disk, "asking for disk must sample it")

        // Long enough that a sampler which DID run would clear its minimum interval
        // and return a reading. Without this pause an ungated sampler still reports
        // nil — for want of an interval, not for want of being asked — and the gate
        // would appear to work while doing nothing.
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertNil(m.sample(needs: [.cpu]).disk,
                     "disk not asked for: must report nothing, not a fresh reading")
    }

    // ── Helper ────────────────────────────────────────────────────────────────

    private func snapshot(read: Double?, written: Double?) -> SystemMetrics.Snapshot {
        let disk = read.flatMap { r in
            written.map {
                DiskActivity.Sample(bytesReadPerSec: r, bytesWrittenPerSec: $0, interval: 1)
            }
        }
        return SystemMetrics.Snapshot(cpu: nil, memory: nil, gpu: nil, network: nil,
                                      disk: disk, cpuTemperature: nil, gpuTemperature: nil,
                                      fans: [])
    }
}
