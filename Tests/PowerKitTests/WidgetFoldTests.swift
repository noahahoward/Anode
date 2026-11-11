import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// Anode's own menu bar widgets can be folded away behind the Menu Bar Hider's chevron: the status items are destroyed, and
/// their config is untouched so they come back when the hider turns off.
final class WidgetFoldTests: XCTestCase {

    private typealias C = MenuBarWidgetController

    private let stored = [
        WidgetConfig(metricID: "batteryDrain", style: .textWithLabel),
        WidgetConfig(metricID: "cpuUsage", style: .textWithLabel),
        WidgetConfig(metricID: "memoryUsage", style: .text),
        WidgetConfig(metricID: "groupPlaceholder", style: .group),
    ]

    func testFoldedMetricsAreRemoved() {
        let ids = C.effectiveConfigs(stored, density: .full, folded: ["cpuUsage", "groupPlaceholder"]).map(\.metricID)
        XCTAssertEqual(ids, ["batteryDrain", "memoryUsage"])
    }

    func testFoldedSetEmptyChangesNothing() {
        XCTAssertEqual(C.effectiveConfigs(stored, density: .full, folded: []), C.effectiveConfigs(stored, density: .full))
        XCTAssertEqual(C.effectiveConfigs(stored, density: .compact, folded: []), C.effectiveConfigs(stored, density: .compact))
    }

    func testFoldAppliesAfterDensity() {
        let compact = C.effectiveConfigs(stored, density: .compact, folded: ["memoryUsage"])
        XCTAssertEqual(compact.map(\.metricID), ["batteryDrain", "cpuUsage", "groupPlaceholder"])
        XCTAssertEqual(compact[0].style, .text, "compact still drops the label of the widgets that remain")
        // The single item is the first real reading; folding that metric removes the item.
        XCTAssertEqual(C.effectiveConfigs(stored, density: .single, folded: ["batteryDrain"]), [])
        XCTAssertEqual(C.effectiveConfigs(stored, density: .single, folded: ["cpuUsage"]).map(\.metricID), ["batteryDrain"])
    }

    func testGroupWidgetCanBeFolded() {
        let ids = C.effectiveConfigs(stored, density: .full, folded: ["groupPlaceholder"]).map(\.metricID)
        XCTAssertFalse(ids.contains("groupPlaceholder"))
    }

    /// The pill lists the widgets that exist: none while the widget master switch is off, and one entry per metric.
    func testWidgetKeysSkipDisabledWidgetsAndDuplicates() {
        let configs = [WidgetConfig(metricID: "cpuUsage", style: .text), WidgetConfig(metricID: "cpuUsage", style: .sparkline),
                       WidgetConfig(metricID: "memoryUsage", style: .text, enabled: false),
                       WidgetConfig(metricID: "groupPlaceholder", style: .group)]
        let keys = C.widgetKeys(for: configs, masterEnabled: true, title: { "T-\($0)" })
        XCTAssertEqual(keys.map(\.metricID), ["cpuUsage", "groupPlaceholder"])
        XCTAssertEqual(keys[0].title, "T-cpuUsage")
        XCTAssertEqual(C.widgetKeys(for: configs, masterEnabled: false, title: { $0 }).count, 0)
    }

    func testKeyFormat() {
        XCTAssertEqual(C.key(forMetricID: "cpuUsage"), "dev.anode.app|widget.cpuUsage")
    }

    /// A folded widget must be destroyed, never made invisible: `isVisible = false` is saved by macOS per autosave name
    /// and would bring the widget back missing after a crash. Comments may mention it; code may not.
    func testFoldNeverSetsIsVisibleFalse() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AnodeApp/MenuBarWidgets.swift")
        let text = try String(contentsOf: file, encoding: .utf8)
        let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        XCTAssertFalse(code.contains { $0.contains("isVisible = false") })
    }
}
