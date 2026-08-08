import XCTest
@testable import PowerKit

/// The network counters used to be read as `struct if_data`, whose byte fields
/// are 32 bits: 4 GiB of traffic — ~34 s at 1 Gbit/s — and the counter is back
/// near zero. The old code took that decrease as an error and returned nil for
/// the whole aggregate, so the reading blanked out exactly during a big transfer.
/// These tests pin the two halves of the fix that are easy to regress: the
/// counters are differenced at full 64-bit width, and a counter that goes
/// backwards is treated as a reset to be dropped, never as a wrap to be
/// reconstructed into a multi-gigabyte-per-second spike.
final class NetworkThroughputTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let fourGiB = UInt64(UInt32.max) + 1        // 4_294_967_296

    private func counters(_ pairs: [String: (UInt64, UInt64)]) -> [String: NetworkThroughput.Counters] {
        pairs.mapValues { NetworkThroughput.Counters(inBytes: $0.0, outBytes: $0.1) }
    }

    // ── Counter width ─────────────────────────────────────────────────────────

    /// The reason the bug existed, stated as an assertion: the legacy struct is
    /// 32-bit and the one now read is 64-bit. If a future SDK changes either, the
    /// wrap analysis above is void and this should fail loudly.
    func testKernelCounterFieldWidths() {
        let legacy = if_data()
        XCTAssertEqual(MemoryLayout.size(ofValue: legacy.ifi_ibytes), 4)
        XCTAssertEqual(MemoryLayout.size(ofValue: legacy.ifi_obytes), 4)

        let wide = if_data64()
        XCTAssertEqual(MemoryLayout.size(ofValue: wide.ifi_ibytes), 8)
        XCTAssertEqual(MemoryLayout.size(ofValue: wide.ifi_obytes), 8)

        // The struct actually walked: its ifmd_data is that 64-bit if_data64.
        XCTAssertEqual(MemoryLayout.size(ofValue: ifmibdata().ifmd_data.ifi_ibytes), 8)
    }

    // ── Crossing what used to be the wrap ─────────────────────────────────────

    func testDeltaAcrossThe32BitBoundaryIsTheTrueByteCount() {
        let net = NetworkThroughput()
        let before = fourGiB - 1_000                      // 1 kB short of the old wrap
        let moved: UInt64 = 3_000                         // straddles it

        XCTAssertNil(net.sample(counters: counters(["en0": (before, before)]), at: t0),
                     "first read has no interval to average over")

        let s = net.sample(counters: counters(["en0": (before + moved, before + moved)]),
                           at: t0 + 1)
        let sample = try! XCTUnwrap(s)
        XCTAssertEqual(sample.bytesInPerSec, 3_000, accuracy: 0.001)
        XCTAssertEqual(sample.bytesOutPerSec, 3_000, accuracy: 0.001)
        XCTAssertEqual(sample.interfaces.first?.name, "en0")
        XCTAssertEqual(sample.interfaces.first?.inPerSec ?? 0, 3_000, accuracy: 0.001)
    }

    /// Counters well past 2^32 in both endpoints — nothing in the path narrows.
    func testCountersFarAboveThe32BitRangeAreNotTruncated() {
        let net = NetworkThroughput()
        let before = fourGiB * 5 + 12_345
        _ = net.sample(counters: counters(["en0": (before, before)]), at: t0)

        let sample = try! XCTUnwrap(net.sample(
            counters: counters(["en0": (before + 500_000, before + 250_000)]), at: t0 + 2))
        XCTAssertEqual(sample.bytesInPerSec, 250_000, accuracy: 0.001)
        XCTAssertEqual(sample.bytesOutPerSec, 125_000, accuracy: 0.001)
        XCTAssertEqual(sample.interval, 2, accuracy: 0.001)
    }

    // ── Resets are not wraps ──────────────────────────────────────────────────

    /// A VPN going down and back up recreates utun3 with its counters at zero.
    /// Reconstructing that as a wrapping delta would print ~2 GB/s over a 2 s
    /// tick; the interface must simply be absent for one tick instead.
    func testCounterResetDropsTheInterfaceRatherThanSpiking() {
        let net = NetworkThroughput()
        _ = net.sample(counters: counters(["en0": (1_000_000, 500_000),
                                           "utun3": (fourGiB / 40, fourGiB / 40)]), at: t0)

        let sample = try! XCTUnwrap(net.sample(
            counters: counters(["en0": (1_400_000, 700_000),
                                "utun3": (0, 0)]),               // recreated, counters at zero
            at: t0 + 2))

        XCTAssertEqual(sample.interfaces.map(\.name), ["en0"],
                       "the reset interface must not be reported at all")
        XCTAssertEqual(sample.bytesInPerSec, 200_000, accuracy: 0.001)
        XCTAssertEqual(sample.bytesOutPerSec, 100_000, accuracy: 0.001)
        XCTAssertLessThan(sample.totalPerSec, 1_000_000,
                          "a reset must never become a gigabytes-per-second headline")
    }

    /// The reset interface picks up from its new baseline on the following tick,
    /// so it is out of the reading for exactly one tick and no longer.
    func testInterfaceResumesFromItsFreshBaselineAfterAReset() {
        let net = NetworkThroughput()
        _ = net.sample(counters: counters(["utun3": (900_000, 900_000)]), at: t0)
        XCTAssertNil(net.sample(counters: counters(["utun3": (0, 0)]), at: t0 + 2),
                     "nothing left to report once the only interface reset")

        let sample = try! XCTUnwrap(net.sample(counters: counters(["utun3": (60_000, 20_000)]),
                                               at: t0 + 4))
        XCTAssertEqual(sample.bytesInPerSec, 30_000, accuracy: 0.001)
        XCTAssertEqual(sample.bytesOutPerSec, 10_000, accuracy: 0.001)
    }

    // ── An interface vanishing does not blank the reading ─────────────────────

    func testAggregateSurvivesAnInterfaceDisappearing() {
        let net = NetworkThroughput()
        _ = net.sample(counters: counters(["en0": (10_000_000, 4_000_000),
                                           "utun3": (5_000_000, 5_000_000)]), at: t0)

        // utun3 is gone this tick — under Δ(Σ) the total would have fallen and the
        // whole sample would have been thrown away.
        let sample = try! XCTUnwrap(net.sample(counters: counters(["en0": (12_000_000, 5_000_000)]),
                                               at: t0 + 2))
        XCTAssertEqual(sample.bytesInPerSec, 1_000_000, accuracy: 0.001)
        XCTAssertEqual(sample.bytesOutPerSec, 500_000, accuracy: 0.001)
        XCTAssertEqual(sample.interfaces.map(\.name), ["en0"])
    }

    /// And the vanished interface's baseline is forgotten, so when a new utun3
    /// appears it is differenced against nothing rather than against the dead
    /// tunnel's totals (which would read as a large negative or, if the new
    /// counters happened to be higher, as traffic that never happened).
    func testReappearingInterfaceStartsAFreshBaseline() {
        let net = NetworkThroughput()
        _ = net.sample(counters: counters(["en0": (1_000, 1_000),
                                           "utun3": (900_000_000, 900_000_000)]), at: t0)
        _ = net.sample(counters: counters(["en0": (2_000, 2_000)]), at: t0 + 2)

        let sample = try! XCTUnwrap(net.sample(
            counters: counters(["en0": (3_000, 3_000),
                                "utun3": (999_999_999, 999_999_999)]),   // "back", huge counters
            at: t0 + 4))
        XCTAssertEqual(sample.interfaces.map(\.name), ["en0"],
                       "a reappearing interface contributes only a baseline")
        XCTAssertEqual(sample.bytesInPerSec, 500, accuracy: 0.001)
    }

    // ── Aggregate is the sum of the parts ─────────────────────────────────────

    func testAggregateIsTheSumOfPerInterfaceDeltas() {
        let net = NetworkThroughput()
        _ = net.sample(counters: counters(["en0": (0, 0), "utun3": (0, 0), "awdl0": (0, 0)]), at: t0)

        let sample = try! XCTUnwrap(net.sample(
            counters: counters(["en0": (200, 100), "utun3": (60, 30), "awdl0": (40, 20)]),
            at: t0 + 1))
        XCTAssertEqual(sample.bytesInPerSec, 300, accuracy: 0.001)
        XCTAssertEqual(sample.bytesOutPerSec, 150, accuracy: 0.001)
        XCTAssertEqual(sample.interfaces.map(\.name), ["en0", "utun3", "awdl0"],
                       "busiest first")
    }

    // ── Plausibility bound ────────────────────────────────────────────────────

    func testImplausibleRateDropsThatInterfaceOnly() {
        let net = NetworkThroughput()
        _ = net.sample(counters: counters(["en0": (0, 0), "en1": (0, 0)]), at: t0)

        let absurd = UInt64(NetworkThroughput.maxPlausibleBytesPerSec * 2)  // 200 Gbit/s
        let sample = try! XCTUnwrap(net.sample(
            counters: counters(["en0": (1_000, 1_000), "en1": (absurd, 0)]), at: t0 + 1))
        XCTAssertEqual(sample.interfaces.map(\.name), ["en0"])
        XCTAssertEqual(sample.bytesInPerSec, 1_000, accuracy: 0.001)
    }

    // ── Interval handling ─────────────────────────────────────────────────────

    func testTooShortAnIntervalReportsNothing() {
        let net = NetworkThroughput()
        _ = net.sample(counters: counters(["en0": (0, 0)]), at: t0)
        XCTAssertNil(net.sample(counters: counters(["en0": (1_000, 0)]), at: t0 + 0.01))
    }

    func testAnIdleInterfaceReportsZeroRatherThanNothing() {
        let net = NetworkThroughput()
        _ = net.sample(counters: counters(["en0": (7_000, 7_000)]), at: t0)

        let sample = try! XCTUnwrap(net.sample(counters: counters(["en0": (7_000, 7_000)]),
                                               at: t0 + 2))
        XCTAssertEqual(sample.totalPerSec, 0)
        XCTAssertTrue(sample.interfaces.isEmpty, "no row for a link that moved nothing")
    }

    // ── The live path ─────────────────────────────────────────────────────────

    func testLiveCountersReadAndProduceAPlausibleSample() throws {
        let counters = try XCTUnwrap(NetworkThroughput.readCounters(),
                                     "no interface counters from net.link.generic.ifdata")
        XCTAssertFalse(counters.isEmpty)
        XCTAssertFalse(counters.keys.contains { $0.hasPrefix("lo") }, "loopback must be excluded")

        let net = NetworkThroughput()
        XCTAssertNil(net.sample(), "first live read has no interval")
        Thread.sleep(forTimeInterval: 0.3)

        let sample = try XCTUnwrap(net.sample(), "second live read must produce a sample")
        XCTAssertTrue(sample.bytesInPerSec.isFinite && sample.bytesOutPerSec.isFinite)
        XCTAssertGreaterThanOrEqual(sample.bytesInPerSec, 0)
        XCTAssertGreaterThanOrEqual(sample.bytesOutPerSec, 0)
        XCTAssertLessThanOrEqual(sample.bytesInPerSec, NetworkThroughput.maxPlausibleBytesPerSec)
        XCTAssertLessThanOrEqual(sample.bytesOutPerSec, NetworkThroughput.maxPlausibleBytesPerSec)
        XCTAssertGreaterThan(sample.interval, 0.05)
    }
}
