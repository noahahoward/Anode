import XCTest
@testable import PowerKit

/// The stats panel's ordering resolver: which metrics show, in what order.
///
/// Three inputs — the user's saved order (empty until they edit), their hidden
/// set, and whatever metrics this build actually registered — and one rule:
/// the user's arrangement wins wherever it speaks, the subject-grouped default
/// speaks everywhere else, and nothing is ever silently dropped.
final class PanelOrderTests: XCTestCase {

    private let all = PanelOrder.defaultOrder.map(\.rawValue)

    // ── The default: grouped by SUBJECT, not by data source ─────────────────

    /// The request that created this file: "cpu temps and cpu % should be right
    /// above/below each other". The registry's categories put every temperature
    /// in a Sensors block at the bottom, three groups away from the load it
    /// belongs to.
    func testDefaultPutsEachTemperatureBesideItsLoad() {
        func index(_ id: MetricID) -> Int? { all.firstIndex(of: id.rawValue) }
        XCTAssertEqual(index(.cpuTemperature), index(.cpuUsage).map { $0 + 1 },
                       "CPU temperature is not directly under CPU usage")
        XCTAssertEqual(index(.gpuTemperature), index(.gpuUsage).map { $0 + 1 },
                       "GPU temperature is not directly under GPU usage")
        // The fan is the machine's response to those temperatures; it rides
        // with them, not in a distant hardware block.
        XCTAssertEqual(index(.fanSpeed), index(.gpuTemperature).map { $0 + 1 })
    }

    func testDefaultCoversEveryPanelMetricExactlyOnce() {
        XCTAssertEqual(Set(all).count, all.count, "duplicate in the default order")
        // The group placeholder is the widget that OPENS this panel; it must
        // never be offered a row inside itself.
        XCTAssertFalse(all.contains(MetricID.groupPlaceholder.rawValue))
    }

    // ── Resolution ──────────────────────────────────────────────────────────

    /// No saved order, nothing hidden: the default, filtered to what exists.
    func testEmptySettingsYieldTheDefaultForAvailableMetrics() {
        let available = [MetricID.cpuUsage, .batteryDrain, .cpuTemperature]
        XCTAssertEqual(
            PanelOrder.visible(saved: [], hidden: [], available: available),
            [MetricID.batteryDrain.rawValue, MetricID.cpuUsage.rawValue,
             MetricID.cpuTemperature.rawValue])
    }

    func testSavedOrderWinsOverTheDefault() {
        let available = [MetricID.cpuUsage, .batteryDrain]
        XCTAssertEqual(
            PanelOrder.visible(saved: [MetricID.cpuUsage.rawValue,
                                       MetricID.batteryDrain.rawValue],
                               hidden: [], available: available),
            [MetricID.cpuUsage.rawValue, MetricID.batteryDrain.rawValue])
    }

    func testHiddenMetricsAreDroppedFromVisibleButKeepTheirSlotInFull() {
        let available = [MetricID.cpuUsage, .batteryDrain, .memoryUsage]
        let saved = [MetricID.memoryUsage.rawValue, MetricID.batteryDrain.rawValue,
                     MetricID.cpuUsage.rawValue]
        XCTAssertEqual(
            PanelOrder.visible(saved: saved, hidden: [MetricID.batteryDrain.rawValue],
                               available: available),
            [MetricID.memoryUsage.rawValue, MetricID.cpuUsage.rawValue])
        // The editor lists hidden rows in place, unchecked — hiding must not
        // cost a metric its position.
        XCTAssertEqual(
            PanelOrder.fullOrder(saved: saved, available: available), saved)
    }

    /// A metric this build registers that the saved order has never seen — a
    /// NEW metric, added after the user arranged things — slots in at its
    /// default position relative to its neighbours, not at the end of the list.
    func testANewMetricJoinsAtItsDefaultNeighbourNotAtTheEnd() {
        let available = [MetricID.cpuUsage, .cpuTemperature, .memoryUsage]
        // The user arranged memory above cpu, before cpuTemperature existed.
        let saved = [MetricID.memoryUsage.rawValue, MetricID.cpuUsage.rawValue]
        XCTAssertEqual(
            PanelOrder.fullOrder(saved: saved, available: available),
            [MetricID.memoryUsage.rawValue, MetricID.cpuUsage.rawValue,
             MetricID.cpuTemperature.rawValue],
            "cpuTemperature's default place is directly after cpuUsage")
    }

    /// A saved ID this build does not register — a metric from a module that is
    /// not loaded — is preserved in the full order (same principle the widget
    /// list documents: never silently un-bind) but cannot render, so it is
    /// absent from visible.
    func testAnUnknownSavedIDIsPreservedInFullAndAbsentFromVisible() {
        let available = [MetricID.cpuUsage]
        let saved = ["future.metric", MetricID.cpuUsage.rawValue]
        XCTAssertEqual(PanelOrder.fullOrder(saved: saved, available: available), saved)
        XCTAssertEqual(PanelOrder.visible(saved: saved, hidden: [], available: available),
                       [MetricID.cpuUsage.rawValue])
    }

    /// A registered metric the DEFAULT has never heard of (a future category)
    /// still shows: appended after everything the default does know.
    func testAMetricOutsideTheDefaultOrderIsAppendedNotLost() {
        let novel = MetricID("future.subsystem.metric")
        let available = [MetricID.cpuUsage, novel]
        XCTAssertEqual(
            PanelOrder.visible(saved: [], hidden: [], available: available),
            [MetricID.cpuUsage.rawValue, novel.rawValue])
    }

    /// Resolution is a pure function: same inputs, same answer, every time.
    func testResolutionIsDeterministic() {
        let available = PanelOrder.defaultOrder.shuffled()
        let a = PanelOrder.visible(saved: [], hidden: [], available: available)
        let b = PanelOrder.visible(saved: [], hidden: [], available: available)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, all, "available-set order must not leak into the answer")
    }
}
