import XCTest
@testable import PowerKit

/// Sampling overlapped itself.
///
/// `refresh()` dispatched onto the global CONCURRENT queue, so a slow tick simply
/// ran alongside the next one, and both mutated the same unprotected state: the
/// monitor's rolling rail windows and paired wall/awake timestamps,
/// `CPUUsage.previous`, `NetworkThroughput.previous`, and the SMC wrapper, which
/// takes no lock at all. Concurrent Swift Dictionary mutation is a crash, not a
/// wrong number.
final class SamplingGateTests: XCTestCase {

    func testATickArrivingWhileOneIsRunningIsTurnedAway() {
        let gate = SamplingGate()
        let queue = DispatchQueue(label: "test.sampling.serial")
        let running = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)

        XCTAssertTrue(gate.submit(on: queue) {
            running.signal()
            release.wait()
        })
        running.wait()   // the first sample is now definitely inside

        XCTAssertFalse(gate.submit(on: queue) {
            XCTFail("a second sample ran while the first was still in the monitor")
        })
        XCTAssertEqual(gate.dropped, 1)

        release.signal()
        // Serial queue: this returns only once the previous block AND the release
        // that follows it have run.
        queue.sync {}
        XCTAssertTrue(gate.submit(on: queue) {},
                      "the gate must reopen the moment the sample finishes")
        XCTAssertEqual(gate.dropped, 1, "finishing a sample is not a drop")
        queue.sync {}
    }

    /// The guarantee has to come from the gate rather than from the queue it
    /// happens to be handed — the code this replaces was handed a concurrent one.
    func testConcurrentTicksNeverOverlapAndEveryOneIsAccountedFor() {
        let gate = SamplingGate()
        let queue = DispatchQueue(label: "test.sampling.concurrent", attributes: .concurrent)
        let group = DispatchGroup()
        let lock = NSLock()
        var inside = 0, mostInsideAtOnce = 0, admitted = 0

        let attempts = 500
        DispatchQueue.concurrentPerform(iterations: attempts) { _ in
            group.enter()
            let ok = gate.submit(on: queue) {
                lock.lock()
                inside += 1
                mostInsideAtOnce = max(mostInsideAtOnce, inside)
                lock.unlock()
                // Long enough that overlapping would be the normal outcome, not a
                // race that has to be caught: a real tick takes milliseconds.
                Thread.sleep(forTimeInterval: 0.0002)
                lock.lock()
                inside -= 1
                lock.unlock()
                group.leave()
            }
            if ok {
                lock.lock(); admitted += 1; lock.unlock()
            } else {
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)

        lock.lock()
        let peak = mostInsideAtOnce, ran = admitted
        lock.unlock()
        XCTAssertEqual(peak, 1, "two samples were inside the monitor at once")
        XCTAssertEqual(ran + gate.dropped, attempts, "a tick was neither run nor counted")
        XCTAssertGreaterThan(gate.dropped, 0,
                             "nothing contended, so the serialisation this asserts is vacuous")
    }

    /// The sampling block returns early in two places — no snapshot, delegate gone.
    /// If either could leave the gate held, sampling would stop for good and in
    /// silence, which is a far worse failure than the overlap it prevents. That is
    /// why releasing the gate is the gate's job and not the block's.
    func testTheGateIsReleasedWhenTheSampleReturnsEarly() {
        let gate = SamplingGate()
        let queue = DispatchQueue(label: "test.sampling.early")
        for tick in 1...3 {
            XCTAssertTrue(gate.submit(on: queue) { return },
                          "tick \(tick) was refused: an earlier one never released the gate")
            queue.sync {}
        }
        XCTAssertEqual(gate.dropped, 0)
    }

    /// Dropped ticks are gaps in the record. Counting them privately would only
    /// move the silence somewhere else.
    func testTheDropCountIsSurfacedAsAMetric() {
        let r = MetricRegistry()
        r.registerSamplerMetrics()
        XCTAssertNil(r.value(for: .samplerDrops),
                     "before the first tick there is no count — which is not a count of zero")

        r.update(droppedSamples: 0)
        XCTAssertEqual(r.value(for: .samplerDrops)?.text, "0",
                       "zero drops IS the measurement and must be shown as one")

        r.update(droppedSamples: 7)
        let v = r.value(for: .samplerDrops)
        XCTAssertEqual(v?.value, 7)
        XCTAssertEqual(v?.text, "7")
        XCTAssertFalse(v?.isEstimate ?? true, "drops are counted, not modelled")

        XCTAssertTrue(MetricRegistry.shared.descriptors().map(\.id).contains(.samplerDrops),
                      "a count no widget can bind to is not surfaced")
    }

    // ── Interaction with the sleep-gap detection ────────────────────────────
    //
    // These pin behaviour the drop must not disturb: they hold against the
    // pre-drop tree by design, because their job is to fail if dropped ticks are
    // ever "handled" in a way that breaks the gap logic.

    /// A drop must be a no-op on the monitor. The moment dropping became something
    /// the pipeline reacted to — resetting, or recording a placeholder interval —
    /// the next admitted tick would stop measuring the whole elapsed span, and the
    /// sleep check would lose its only chance to see it.
    func testADroppedTickLeavesTheMonitorsAccumulatorsAlone() throws {
        let m = try XCTUnwrap(PowerMonitor(scale: makeExactScale()))
        m.tick(full: true, attribution: false)
        Thread.sleep(forTimeInterval: 0.1)
        m.tick(full: true, attribution: false)

        let gate = SamplingGate()
        let queue = DispatchQueue(label: "test.sampling.noop")
        let running = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        XCTAssertTrue(gate.submit(on: queue) { running.signal(); release.wait() })
        running.wait()

        let before = m.accumulators
        for _ in 0..<3 {
            XCTAssertFalse(gate.submit(on: queue) { XCTFail("a dropped tick sampled") })
        }
        XCTAssertEqual(m.accumulators, before, "a dropped tick touched the monitor")
        XCTAssertEqual(gate.dropped, 3)

        release.signal()
        queue.sync {}
    }

    /// Drops make the next interval longer, and that is all they do. A rusage
    /// counter difference over 48 s is a real difference over 48 s, so every span
    /// a plausible run of drops can produce must stay OUT of the gap path —
    /// otherwise a machine busy enough to drop ticks would start discarding its
    /// own measurements as though it had been asleep.
    func testARunOfDroppedTicksIsALongerSampleNotASleep() {
        // Consecutive drops at the 8 s hidden cadence.
        for dropped in 1...13 {
            let wall = 8.0 * Double(dropped + 1)
            guard wall <= PowerMonitor.maxPlausibleInterval else { break }
            XCTAssertFalse(PowerMonitor.straddlesGap(wall: wall, awake: wall),
                           "\(dropped) dropped ticks became a phantom sleep")
        }
    }

    /// The other direction, and it is deliberate rather than a false positive: a
    /// stall past the plausible limit IS a gap in observation, whatever stopped
    /// the sampler. The accumulators fuse samples over time, so carrying them
    /// across two minutes nothing measured would describe the machine as it was
    /// before the stall and call it now.
    func testAStallPastThePlausibleLimitIsTreatedAsTheGapItIs() {
        XCTAssertTrue(PowerMonitor.straddlesGap(wall: 130, awake: 130))
    }

    /// And a real sleep is still caught when the tick that would have straddled it
    /// was dropped — the drop leaves the monitor's clocks alone, so the next
    /// admitted tick still sees the whole nine hours.
    func testASleepIsStillCaughtWhenTheTickThatWouldHaveSeenItWasDropped() {
        XCTAssertTrue(PowerMonitor.straddlesGap(wall: 32_400 + 8, awake: 12))
        // A three-minute nap with a couple of drops either side of it: under the
        // duration limit on the wall clock, and caught only by the awake clock.
        XCTAssertTrue(PowerMonitor.straddlesGap(wall: 180, awake: 24))
    }
}
