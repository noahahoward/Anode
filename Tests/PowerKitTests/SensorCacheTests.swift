import XCTest
@testable import PowerKit

/// The Sensors pane used to call `Sensors.temperatures()` inline on every UI tick,
/// which is a full ~270-key AppleSMC sweep — 90 ms of wall clock and 10 ms of CPU
/// on this machine — on the main thread, twice a second's worth of the app's entire
/// idle budget. `SensorCache` is the rule that stopped it, and the rule is what
/// these tests pin: whether a sweep is issued must depend only on the clock, never
/// on the hardware the tests happen to run on. So the sweep and the clock are both
/// fakes here and no SMC is opened at all.
final class SensorCacheTests: XCTestCase {

    /// A sweep that counts how many times it was asked to read the SMC.
    private final class FakeSMC {
        private(set) var sweeps = 0
        var value: Double = 50
        func sweep() -> [SensorReading] {
            sweeps += 1
            return [SensorReading(key: "Tp00", name: "CPU performance sensor 1",
                                  kind: .temperature, value: value, unit: "°C")]
        }
    }

    /// A clock the test moves by hand. Real time in a cache test would make the
    /// answer depend on how long the test itself took.
    private final class FakeClock {
        var now = Date(timeIntervalSince1970: 1_000_000)
        func advance(_ s: TimeInterval) { now += s }
    }

    private func makeCache(interval: TimeInterval = 5)
        -> (SensorCache, FakeSMC, FakeClock) {
        let smc = FakeSMC(), clock = FakeClock()
        let cache = SensorCache(interval: interval,
                                now: { clock.now },
                                sweep: { smc.sweep() })
        return (cache, smc, clock)
    }

    // ── The rule ────────────────────────────────────────────────────────────

    func testNoSweepUntilAsked() {
        let (cache, smc, _) = makeCache()
        XCTAssertEqual(smc.sweeps, 0, "constructing the cache must not touch the SMC")
        XCTAssertNil(cache.latest)
        XCTAssertTrue(cache.isStale)
    }

    func testFirstRefreshSweeps() {
        let (cache, smc, _) = makeCache()
        XCTAssertEqual(cache.refreshIfStale()?.count, 1)
        XCTAssertEqual(smc.sweeps, 1)
        XCTAssertFalse(cache.isStale)
    }

    /// The whole point: a second ask inside the window issues no SMC traffic.
    func testSecondRefreshInsideTheWindowDoesNotSweep() {
        let (cache, smc, clock) = makeCache()
        cache.refreshIfStale()
        clock.advance(4.9)
        cache.refreshIfStale()
        XCTAssertEqual(smc.sweeps, 1)
    }

    func testRefreshSweepsAgainOnceTheWindowHasPassed() {
        let (cache, smc, clock) = makeCache()
        cache.refreshIfStale()
        clock.advance(5.0)
        XCTAssertTrue(cache.isStale)
        cache.refreshIfStale()
        XCTAssertEqual(smc.sweeps, 2)
    }

    /// The shape the pane actually drives: a tick every 2 s over 10 s. Before the
    /// fix that was 5 sweeps — one per tick, on the main thread. The 5 s window
    /// makes it 2.
    func testTickCadenceIssuesOneSweepPerWindowNotOnePerTick() {
        let (cache, smc, clock) = makeCache()
        for _ in 0..<5 {
            cache.refreshIfStale()
            clock.advance(2)
        }
        XCTAssertEqual(smc.sweeps, 2, "5 ticks at 2 s across a 5 s window is 2 sweeps")
    }

    // ── What the cache reports ──────────────────────────────────────────────

    func testLatestServesTheCachedListWithoutSweeping() {
        let (cache, smc, clock) = makeCache()
        cache.refreshIfStale()
        smc.value = 91            // the SMC moved, but nobody asked for a re-read
        clock.advance(1)
        XCTAssertEqual(cache.latest?.first?.value, 50)
        XCTAssertEqual(smc.sweeps, 1)
    }

    func testRefreshPublishesTheNewList() {
        let (cache, smc, clock) = makeCache()
        cache.refreshIfStale()
        smc.value = 91
        clock.advance(6)
        cache.refreshIfStale()
        XCTAssertEqual(cache.latest?.first?.value, 91)
    }

    /// nil and [] are different claims. "Not read yet" must never render as "this
    /// machine has no readable sensors" — that is a measurement nobody has made.
    func testUnreadIsNilNotEmpty() {
        let (cache, _, _) = makeCache()
        XCTAssertNil(cache.latest)
        XCTAssertNil(cache.age)
    }

    func testEmptySweepIsRecordedAsEmptyNotAsUnread() {
        let clock = FakeClock()
        let cache = SensorCache(interval: 5, now: { clock.now }, sweep: { [] })
        cache.refreshIfStale()
        XCTAssertEqual(cache.latest?.isEmpty, true,
                       "a machine that genuinely reports nothing is a measurement, not a gap")
    }

    func testAgeTracksTheClock() {
        let (cache, _, clock) = makeCache()
        cache.refreshIfStale()
        clock.advance(3)
        XCTAssertEqual(cache.age ?? -1, 3, accuracy: 0.001)
    }

    // ── Concurrency ─────────────────────────────────────────────────────────

    /// The SMC user client is one serialized resource. Several threads that all see
    /// a stale cache must still produce one sweep between them, or the fix trades a
    /// main-thread stall for a queue of 90 ms background sweeps.
    func testConcurrentRefreshesIssueOneSweep() {
        let clock = FakeClock()
        let counter = FakeSMC()
        let counterLock = NSLock()
        let cache = SensorCache(interval: 5, now: { clock.now }, sweep: {
            counterLock.lock(); defer { counterLock.unlock() }
            Thread.sleep(forTimeInterval: 0.02)   // stand in for the 90 ms sweep
            return counter.sweep()
        })

        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            cache.refreshIfStale()
        }
        XCTAssertEqual(counter.sweeps, 1)
    }
}
