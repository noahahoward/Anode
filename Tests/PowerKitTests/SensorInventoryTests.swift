import XCTest
@testable import PowerKit

/// One sweep must answer every sensor question.
///
/// `Sensors.cpuTemperature()`, `gpuTemperature()` and `fans()` each perform a
/// FULL SMC sweep — there is no cache beneath `snapshot()`, so it re-reads every
/// classified key and every fan on each call. Measured on this machine: 88 ms
/// wall / 9.3 ms CPU for one sweep, 255 ms / 27.9 ms for the three together.
/// `SystemMetrics` was making all three every 5 s, spending 0.56% of one core to
/// read the same keys three times over.
///
/// The fix moved the derivations onto `Inventory` so a caller can take one
/// snapshot and read all three off it. These tests pin the part that could
/// silently rot: that the two paths still mean the same thing. A divergence
/// would put a different CPU temperature in the widget than in the pane, which
/// is exactly the class of bug this project keeps finding.
final class SensorInventoryTests: XCTestCase {

    /// Skips rather than fails where no SMC is reachable — CI, a VM, or an
    /// Intel Mac. A test that cannot observe the hardware must not claim a
    /// verdict about it.
    private func requireSensors() throws -> Sensors.Inventory {
        let inv = Sensors.inventory()
        try XCTSkipIf(inv.keysTotal == 0, "no AppleSMC user client here")
        return inv
    }

    func testInventoryDerivationsMatchTheStandaloneAccessors() throws {
        let inv = try requireSensors()

        // Temperatures drift between sweeps, so compare with a tolerance wide
        // enough for real thermal movement and far too narrow to hide a wrong
        // key-family filter — which is what this is actually guarding.
        if let a = inv.cpuTemperature, let b = Sensors.cpuTemperature() {
            XCTAssertEqual(a, b, accuracy: 3.0, "CPU temperature diverged between paths")
        } else {
            XCTAssertEqual(inv.cpuTemperature == nil, Sensors.cpuTemperature() == nil,
                           "one path found a CPU sensor and the other did not")
        }
        if let a = inv.gpuTemperature, let b = Sensors.gpuTemperature() {
            XCTAssertEqual(a, b, accuracy: 3.0, "GPU temperature diverged between paths")
        } else {
            XCTAssertEqual(inv.gpuTemperature == nil, Sensors.gpuTemperature() == nil,
                           "one path found a GPU sensor and the other did not")
        }
        XCTAssertEqual(inv.fans.count, Sensors.fans().count)
        XCTAssertEqual(inv.temperatures.count, Sensors.temperatures().count)
    }

    /// The whole point of the refactor: everything a caller might want is on one
    /// snapshot, so nobody has a reason to take three.
    func testOneSnapshotAnswersEveryQuestionSystemMetricsAsks() throws {
        let inv = try requireSensors()
        XCTAssertFalse(inv.temperatures.isEmpty)
        XCTAssertNotNil(inv.cpuTemperature)
        XCTAssertNotNil(inv.hottest)
    }

    /// Derivations must read the classified temperature set, not every reading.
    /// Fans are appended to `readings` so a widget can bind one, and folding a
    /// 2000 rpm fan into a temperature mean would be a spectacular way to report
    /// a boiling CPU.
    /// "Not measured" must stay distinguishable from "measured, and there are
    /// none". The SMC sweep is skipped while the window is hidden, so a hidden
    /// snapshot carries an empty fan list BY DESIGN — and the Fans pane rendered
    /// that as "this machine reports no fans" on a machine with two, until the
    /// next visible tick corrected it.
    func testASkippedSweepIsNotReportedAsNoSensors() {
        let m = SystemMetrics()
        let skipped = m.sample(needs: [.cpu])
        XCTAssertFalse(skipped.sensorsSampled,
                       "a sample that never read the SMC must say so")
        XCTAssertTrue(skipped.fans.isEmpty, "and it must not invent readings either")

        let full = m.sample(needs: .all)
        XCTAssertTrue(full.sensorsSampled)
    }

    /// The flag has to follow the REQUEST, not whether anything came back — a
    /// fanless Mac genuinely reports zero fans from a sweep that did happen, and
    /// that must remain sayable.
    func testTheFlagTracksTheRequestNotTheResult() {
        let m = SystemMetrics()
        XCTAssertTrue(m.sample(needs: .sensors).sensorsSampled)
        XCTAssertFalse(m.sample(needs: []).sensorsSampled)
    }

    func testFanReadingsAreNotFoldedIntoTemperatures() throws {
        let inv = try requireSensors()
        XCTAssertFalse(inv.temperatures.contains { $0.kind == .fan })
        if let cpu = inv.cpuTemperature {
            XCTAssertLessThan(cpu, 120, "a fan rpm has leaked into the temperature mean")
            XCTAssertGreaterThan(cpu, 0)
        }
    }
}
