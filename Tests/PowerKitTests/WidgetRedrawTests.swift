import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// An unchanged reading draws nothing.
///
/// The menu bar widgets used to build a picture and hand it to their status item on every tick, and AppKit then redrew
/// the item (a snapshot of the button rendered into a bitmap) for pixels that were already there. The widgets now keep
/// what each item last drew; these tests count the pictures handed to the items.
final class WidgetRedrawTests: XCTestCase {

    /// The one reading these tests move by hand.
    private final class Reading {
        var value = 11.0
        var text = "11%"
    }

    private struct Rig {
        let controller: MenuBarWidgetController
        let reading: Reading
        let metric: MetricID
    }

    /// A controller over a registry of its own with one metric whose reading is `reading`, showing it in `styles`.
    private func rig(styles: [WidgetStyle]) throws -> Rig {
        let (defaults, name) = try TestDefaults.make(owner: "WidgetRedraw", test: self.name)
        let reading = Reading()
        let metric = MetricID("test.widgetRedraw.\(UUID().uuidString)")
        let registry = MetricRegistry()
        registry.register(MetricDescriptor(id: metric, title: "Redraw", shortTitle: "Rd", unit: .percent,
                                           category: "Test", higherIsWorse: true)) {
            MetricValue(value: reading.value, text: reading.text, isEstimate: false)
        }
        let controller = MenuBarWidgetController(onClick: { _ in }, defaults: defaults, enabled: true)
        controller.registry = registry
        controller.setConfigs(styles.map { WidgetConfig(metricID: metric.rawValue, style: $0) })
        addTeardownBlock { controller.setEnabled(false); TestDefaults.destroy(defaults, name) }
        try XCTSkipIf(controller.statusButtons.count != styles.count, "no status bar in this environment")
        return Rig(controller: controller, reading: reading, metric: metric)
    }

    func testAnUnchangedReadingAssignsNoImage() throws {
        let r = try rig(styles: [.text])
        r.controller.refresh()
        let before = r.controller.imageAssignments
        for _ in 0..<5 { r.controller.refresh() }
        XCTAssertEqual(r.controller.imageAssignments, before, "the same text drew a new picture")
    }

    func testAChangedReadingAssignsOneImage() throws {
        let r = try rig(styles: [.text])
        r.controller.refresh()
        let before = r.controller.imageAssignments
        r.reading.text = "12%"
        r.controller.refresh()
        XCTAssertEqual(r.controller.imageAssignments, before + 1)
        r.controller.refresh()
        XCTAssertEqual(r.controller.imageAssignments, before + 1, "and the new text is drawn once")
    }

    func testALabelledWidgetDrawsOnlyWhenItsTextDoes() throws {
        let r = try rig(styles: [.textWithLabel])
        r.controller.refresh()
        let before = r.controller.imageAssignments
        r.controller.refresh()
        XCTAssertEqual(r.controller.imageAssignments, before)
        r.reading.text = "13%"
        r.controller.refresh()
        XCTAssertEqual(r.controller.imageAssignments, before + 1)
    }

    func testAChangeOfAppearanceDrawsAgain() throws {
        let r = try rig(styles: [.text, .bar])
        r.controller.refresh()
        let before = r.controller.imageAssignments
        r.controller.refresh()
        XCTAssertEqual(r.controller.imageAssignments, before)
        // What the widgets do on the system's note that the menu bar's look changed (and on a change of screen).
        r.controller.invalidateRendered()
        r.controller.refresh()
        XCTAssertEqual(r.controller.imageAssignments, before + 2, "every widget draws again, once")
        r.controller.refresh()
        XCTAssertEqual(r.controller.imageAssignments, before + 2)
    }

    func testMakingTheItemsAgainDrawsThem() throws {
        let r = try rig(styles: [.text])
        r.controller.refresh()
        let before = r.controller.imageAssignments
        r.controller.setConfigs(r.controller.configs)
        XCTAssertGreaterThan(r.controller.imageAssignments, before, "a new item has drawn nothing yet")
        let button = try XCTUnwrap(r.controller.statusButtons.first)
        XCTAssertNotNil(button.image, "the new item shows the reading")
    }

    func testTheWidthFollowsTheTextWhenTheTextChangesWidth() throws {
        let r = try rig(styles: [.text])
        r.controller.refresh()
        let button = try XCTUnwrap(r.controller.statusButtons.first)
        let narrow = try XCTUnwrap(button.image).size.width
        r.reading.text = "100%/hr"
        r.controller.refresh()
        let wide = try XCTUnwrap(button.image).size.width
        XCTAssertGreaterThan(wide, narrow, "a longer text is a wider picture")
        r.reading.text = "1%"
        r.controller.refresh()
        XCTAssertLessThan(try XCTUnwrap(button.image).size.width, wide)
    }

    func testABarDrawsOnlyWhenItsFillOrColourWouldDiffer() throws {
        let r = try rig(styles: [.bar])
        r.controller.refresh()
        let before = r.controller.imageAssignments
        // A different number with the same fill: the text is not in a bar.
        r.reading.text = "11.0%"
        r.controller.refresh()
        XCTAssertEqual(r.controller.imageAssignments, before)
        r.reading.value = 40
        r.controller.refresh()
        XCTAssertEqual(r.controller.imageAssignments, before + 1)
        // Across a colour boundary (past 80 % of the scale the bar goes red).
        r.reading.value = 85
        r.controller.refresh()
        XCTAssertEqual(r.controller.imageAssignments, before + 2)
    }

    func testADotDrawsOnlyWhenItsColourChanges() throws {
        let r = try rig(styles: [.dot])
        r.controller.refresh()
        let before = r.controller.imageAssignments
        r.reading.value = 20
        r.controller.refresh()
        XCTAssertEqual(r.controller.imageAssignments, before, "still green")
        r.reading.value = 95
        r.controller.refresh()
        XCTAssertEqual(r.controller.imageAssignments, before + 1, "red")
    }

    /// Two widgets on one metric keep a key each: with one key between them they redrew each other on every tick.
    func testTwoWidgetsOnOneMetricDoNotRedrawEachOther() throws {
        let r = try rig(styles: [.text, .textWithLabel, .bar])
        r.controller.refresh()
        let before = r.controller.imageAssignments
        for _ in 0..<4 { r.controller.refresh() }
        XCTAssertEqual(r.controller.imageAssignments, before)
    }

    func testASparklineDrawsWhileItsHistoryMoves() throws {
        let r = try rig(styles: [.sparkline])
        r.controller.refresh()
        let before = r.controller.imageAssignments
        r.reading.value = 30
        r.controller.refresh()
        XCTAssertEqual(r.controller.imageAssignments, before + 1, "the history grew")
    }

    func testSeverityLevelAgreesWithSeverityColor() throws {
        let d = MetricDescriptor(id: MetricID("test.severity"), title: "S", shortTitle: "S", unit: .percent,
                                 category: "Test", higherIsWorse: true)
        let cases: [(Double, WidgetRenderer.SeverityLevel, NSColor)] = [
            (10, .green, .systemGreen), (60, .yellow, .systemYellow), (90, .red, .systemRed)]
        for (v, level, color) in cases {
            let value = MetricValue(v, unit: .percent, isEstimate: false)
            XCTAssertEqual(WidgetRenderer.severityLevel(d, value), level)
            XCTAssertEqual(WidgetRenderer.severityColor(d, value), color)
        }
        XCTAssertEqual(WidgetRenderer.severityLevel(d, nil), .neutral)
        XCTAssertEqual(WidgetRenderer.severityColor(d, nil), .secondaryLabelColor)
    }
}
