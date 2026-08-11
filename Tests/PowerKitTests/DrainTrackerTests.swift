import XCTest
@testable import PowerKit

/// Covers the rolling-window tracker and the per-process measures the lenses read.
final class DrainTrackerTests: XCTestCase {

    private let scale = BatteryScale(
        fullChargeCapacity_mAh: 6197, designCapacity_mAh: 6249,
        nominalVoltage_V: 11.58, isCalibrated: false)

    /// `cpu` is given in NANOSECONDS for readability and converted to the mach
    /// absolute time units the real field carries.
    ///
    /// These fixtures previously passed nanoseconds straight into a field that
    /// holds mach units, which made the suite assert the very 41.667x error it
    /// should have caught: a "100%" expectation was really encoding 2.4%. The
    /// conversion belongs here so the tests state what they mean and still
    /// exercise the real unit.
    private func proc(_ pid: pid_t, energy: UInt64, cpu: UInt64,
                      footprint: UInt64 = 0, disk: UInt64 = 0) -> ProcessEnergy {
        let units = UInt64((Double(cpu) / MachTime.nanosPerUnit).rounded())
        return ProcessEnergy(pid: pid, name: "p\(pid)", energy_nJ: energy, pEnergy_nJ: 0,
                      cycles: 0, pCycles: 0, startAbsTime: 1, path: "/usr/bin/p\(pid)",
                      userTime_ns: units, systemTime_ns: 0,
                      footprint: footprint, diskRead: disk, diskWritten: 0)
    }

    private func sweep(_ procs: [ProcessEnergy], at t: Date) -> ProcessSampler.Sweep {
        ProcessSampler.Sweep(
            processes: Dictionary(uniqueKeysWithValues: procs.map { ($0.key, $0) }),
            timestamp: t, attempted: procs.count, denied: 0)
    }

    /// One full core for the whole window must read 100%, matching Activity
    /// Monitor's convention — percent of ONE core, not of the whole machine.
    func testCPUPercentIsPercentOfOneCore() {
        let tracker = DrainTracker(window: 10)
        let t0 = Date()
        _ = tracker.update(with: sweep([proc(1, energy: 0, cpu: 0)], at: t0), scale: scale)

        // 4 s later, having consumed exactly 4 s of CPU time.
        let out = tracker.update(
            with: sweep([proc(1, energy: 1_000_000_000, cpu: 4_000_000_000)],
                        at: t0.addingTimeInterval(4)),
            scale: scale)

        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].cpuPercent, 100, accuracy: 0.01)
    }

    /// A process using four cores flat out reads 400%, not clamped to 100.
    func testMultithreadedProcessExceedsOneHundredPercent() {
        let tracker = DrainTracker(window: 10)
        let t0 = Date()
        _ = tracker.update(with: sweep([proc(1, energy: 0, cpu: 0)], at: t0), scale: scale)
        let out = tracker.update(
            with: sweep([proc(1, energy: 1, cpu: 8_000_000_000)], at: t0.addingTimeInterval(2)),
            scale: scale)
        XCTAssertEqual(out[0].cpuPercent, 400, accuracy: 0.01)
    }

    /// Energy is watts; the joules/second conversion must not drift.
    func testEnergyBecomesWattsAndPercentPerHour() {
        let tracker = DrainTracker(window: 10)
        let t0 = Date()
        _ = tracker.update(with: sweep([proc(1, energy: 0, cpu: 0)], at: t0), scale: scale)
        // 10 J over 5 s = 2 W.
        let out = tracker.update(
            with: sweep([proc(1, energy: 10_000_000_000, cpu: 0)], at: t0.addingTimeInterval(5)),
            scale: scale)
        XCTAssertEqual(out[0].watts, 2, accuracy: 0.001)
        XCTAssertEqual(out[0].percentPerHour,
                       3600 * 2 / scale.joulesPerPercent, accuracy: 0.001)
    }

    /// Memory is instantaneous, so it is reported as-is rather than differenced —
    /// differencing a footprint would report growth, not usage.
    func testMemoryIsNotDifferenced() {
        let tracker = DrainTracker(window: 10)
        let t0 = Date()
        _ = tracker.update(with: sweep([proc(1, energy: 0, cpu: 0, footprint: 100)], at: t0),
                           scale: scale)
        let out = tracker.update(
            with: sweep([proc(1, energy: 1, cpu: 1, footprint: 500)], at: t0.addingTimeInterval(2)),
            scale: scale)
        XCTAssertEqual(out[0].memoryBytes, 500)
    }

    /// A process whose energy counter has not flushed can still be burning CPU.
    /// Recording only on energy change would hide it from the CPU lens entirely.
    func testCPUTrackedEvenWhenEnergyCounterIsStale() {
        let tracker = DrainTracker(window: 10)
        let t0 = Date()
        _ = tracker.update(with: sweep([proc(1, energy: 500, cpu: 0)], at: t0), scale: scale)
        let out = tracker.update(
            with: sweep([proc(1, energy: 500, cpu: 2_000_000_000)], at: t0.addingTimeInterval(2)),
            scale: scale)
        XCTAssertEqual(out.count, 1, "process vanished when only its CPU counter moved")
        XCTAssertEqual(out[0].cpuPercent, 100, accuracy: 0.01)
        XCTAssertEqual(out[0].watts, 0, accuracy: 0.0001)
    }

    /// The regression that made rows flicker: a process is not dropped just because
    /// it was idle across the window.
    func testIdleProcessIsReportedAsZeroNotDropped() {
        let tracker = DrainTracker(window: 10)
        let t0 = Date()
        _ = tracker.update(with: sweep([proc(1, energy: 7, cpu: 7)], at: t0), scale: scale)
        _ = tracker.update(with: sweep([proc(1, energy: 9, cpu: 9)], at: t0.addingTimeInterval(1)),
                           scale: scale)
        let out = tracker.update(
            with: sweep([proc(1, energy: 9, cpu: 9)], at: t0.addingTimeInterval(2)), scale: scale)
        XCTAssertEqual(out.count, 1)
    }

    /// A counter going backwards means pid reuse or a reset, never negative usage.
    func testCounterResetNeverYieldsNegativeRates() {
        let tracker = DrainTracker(window: 10)
        let t0 = Date()
        _ = tracker.update(with: sweep([proc(1, energy: 10_000_000_000, cpu: 5_000_000_000)], at: t0),
                           scale: scale)
        let out = tracker.update(
            with: sweep([proc(1, energy: 5, cpu: 5)], at: t0.addingTimeInterval(2)), scale: scale)
        for d in out {
            XCTAssertGreaterThanOrEqual(d.watts, 0)
            XCTAssertGreaterThanOrEqual(d.cpuPercent, 0)
        }
    }

    /// The rollup has to sum every dimension, not just energy — otherwise the CPU
    /// lens shows one helper's usage as the whole app's.
    func testRollupSumsAllDimensions() {
        let drains = [
            ProcessDrain(name: "a", pid: 1, path: "/Applications/X.app/Contents/MacOS/a",
                         joules: 1, watts: 1, percentPerHour: 1,
                         cpuPercent: 30, memoryBytes: 100, diskReadPerSec: 10, diskWrittenPerSec: 0),
            ProcessDrain(name: "b", pid: 2, path: "/Applications/X.app/Contents/MacOS/b",
                         joules: 2, watts: 2, percentPerHour: 2,
                         cpuPercent: 70, memoryBytes: 200, diskReadPerSec: 5, diskWrittenPerSec: 0),
        ]
        let apps = DrainCalculator.group(drains, scale: scale)
        XCTAssertEqual(apps.count, 1, "both processes belong to the same .app bundle")
        XCTAssertEqual(apps[0].cpuPercent, 100, accuracy: 0.001)
        XCTAssertEqual(apps[0].memoryBytes, 300)
        XCTAssertEqual(apps[0].diskBytesPerSec, 15, accuracy: 0.001)
        XCTAssertEqual(apps[0].processCount, 2)
    }
}
