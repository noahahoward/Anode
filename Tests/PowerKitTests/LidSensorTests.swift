import XCTest
@testable import PowerKit

/// The lid angle sensor: its three-byte report, the polling rates, and a read loop that survives a bad sensor.
final class LidSensorTests: XCTestCase {

    // ── The report ──

    func testReportParsesLittleEndianDegrees() {
        XCTAssertEqual(LidAngleReport.degrees(from: [1, 107, 0, 0], length: 3), 107)
        XCTAssertEqual(LidAngleReport.degrees(from: [1, 0x2C, 0x01], length: 3), 300)
    }

    func testReportRejectsShortWrongIdAndOutOfRange() {
        XCTAssertNil(LidAngleReport.degrees(from: [1, 90], length: 2))
        XCTAssertNil(LidAngleReport.degrees(from: [2, 90, 0], length: 3))
        XCTAssertNil(LidAngleReport.degrees(from: [1, 0xFF, 0xFF], length: 3))
        XCTAssertNil(LidAngleReport.degrees(from: [1, 90, 0], length: 0))
    }

    // ── The rates ──

    func testIdleHzClamps() {
        XCTAssertEqual(LidPollPolicy.idleHz(2), 4)
        XCTAssertEqual(LidPollPolicy.idleHz(50), 30)
        XCTAssertEqual(LidPollPolicy.idleHz(8), 8)
    }

    func testSustainedSlowReadsDropTo60AndRecover() {
        var policy = LidPollPolicy()
        for _ in 0..<4 { XCTAssertEqual(policy.recordRead(seconds: 0.02), 120) }
        XCTAssertEqual(policy.recordRead(seconds: 0.02), 60)
        XCTAssertEqual(policy.recordRead(seconds: 0.001), 120)
    }

    func testOneSlowReadAmongFastOnesNeverDegrades() {
        var policy = LidPollPolicy()
        for _ in 0..<20 {
            _ = policy.recordRead(seconds: 0.02)
            XCTAssertEqual(policy.recordRead(seconds: 0.001), 120)
        }
    }

    // ── The loop ──

    /// Collects what a sensor delivers, from its own queue.
    private final class Sink {
        private let lock = NSLock()
        private var _samples: [Double] = [], _lost = 0
        var samples: [Double] { lock.lock(); defer { lock.unlock() }; return _samples }
        var lost: Int { lock.lock(); defer { lock.unlock() }; return _lost }
        func sample(_ d: Double) { lock.lock(); _samples.append(d); lock.unlock() }
        func lose() { lock.lock(); _lost += 1; lock.unlock() }
    }

    private func wait(_ seconds: TimeInterval) {
        let e = expectation(description: "wait"); e.isInverted = true
        wait(for: [e], timeout: seconds)
    }

    func testDeliversTheAngleAtRoughlyTheRequestedRate() {
        let sensor = LidAngleSensor(readOverride: { 100 })
        let sink = Sink()
        sensor.start(hz: 30, onSample: { d, _ in sink.sample(d) }, onLost: { sink.lose() })
        wait(1.0)
        sensor.stop()
        XCTAssertTrue((15...40).contains(sink.samples.count), "got \(sink.samples.count)")
        XCTAssertTrue(sink.samples.allSatisfy { $0 == 100 })
        XCTAssertEqual(sink.lost, 0)
    }

    func testThreeFailedReadsInARowReportTheSensorLostOnceAndStop() {
        let sensor = LidAngleSensor(readOverride: { nil })
        let sink = Sink()
        sensor.start(hz: 30, onSample: { d, _ in sink.sample(d) }, onLost: { sink.lose() })
        wait(0.6)
        XCTAssertEqual(sink.lost, 1)
        XCTAssertTrue(sink.samples.isEmpty)
        sensor.stop()
    }

    func testOneBadReadAmongGoodOnesIsNotALoss() {
        let calls = NSLock(); var n = 0
        let sensor = LidAngleSensor(readOverride: {
            calls.lock(); defer { calls.unlock() }
            n += 1
            return n % 4 == 0 ? nil : 90
        })
        let sink = Sink()
        sensor.start(hz: 30, onSample: { d, _ in sink.sample(d) }, onLost: { sink.lose() })
        wait(0.8)
        sensor.stop()
        XCTAssertEqual(sink.lost, 0)
        XCTAssertFalse(sink.samples.isEmpty)
    }

    /// A read that hangs must not have another read queued behind it.
    func testASlowReadIsNeverOverlappedByAnother() {
        let lock = NSLock(); var running = 0, peak = 0
        let sensor = LidAngleSensor(readOverride: {
            lock.lock(); running += 1; peak = max(peak, running); lock.unlock()
            Thread.sleep(forTimeInterval: 0.15)
            lock.lock(); running -= 1; lock.unlock()
            return 80
        })
        sensor.start(hz: 120, onSample: { _, _ in }, onLost: {})
        wait(0.8)
        sensor.stop()
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(peak, 1)
    }

    func testNothingIsDeliveredAfterStop() {
        let sensor = LidAngleSensor(readOverride: { 70 })
        let sink = Sink()
        sensor.start(hz: 30, onSample: { d, _ in sink.sample(d) }, onLost: { sink.lose() })
        wait(0.3)
        sensor.stop()
        let count = sink.samples.count
        wait(0.4)
        XCTAssertEqual(sink.samples.count, count)
    }

    func testSensorWithoutADeviceIsNotAvailableAndStartDoesNothing() {
        let sensor = LidAngleSensor(readOverride: nil, available: false)
        XCTAssertFalse(sensor.isAvailable)
        let sink = Sink()
        sensor.start(hz: 30, onSample: { d, _ in sink.sample(d) }, onLost: { sink.lose() })
        wait(0.3)
        XCTAssertTrue(sink.samples.isEmpty)
        sensor.stop()
    }
}
