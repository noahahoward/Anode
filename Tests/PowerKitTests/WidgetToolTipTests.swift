import XCTest
@testable import AnodeApp
@testable import PowerKit

// The group widget binds to no metric, so it has no descriptor — and the tooltip
// treated "no descriptor" as "a metric from another version of Anode". Hovering the
// one widget every default install ships with therefore reported it as broken.
final class WidgetToolTipTests: XCTestCase {

    func testGroupWidgetIsNotReportedAsAnUnknownMetric() {
        let tip = WidgetRenderer.toolTip(metricID: MetricID.groupPlaceholder.rawValue,
                                         descriptor: nil, value: nil)
        XCTAssertFalse(tip.contains("Unknown"), tip)
        XCTAssertEqual(tip, "All readings — click for the list")
    }

    /// The reading is in the widget; a tooltip that repeated it was a new string on every tick, and on a MacBook
    /// Neo each change made macOS pop the old one up beside the pointer.
    func testTheToolTipDoesNotChangeWhenOnlyTheReadingDoes() throws {
        let d = try XCTUnwrap(MetricRegistry.shared.descriptor(for: .cpuUsage))
        func tip(_ text: String, style: WidgetStyle? = nil, estimate: Bool = false) -> String {
            WidgetRenderer.toolTip(metricID: d.id.rawValue, descriptor: d,
                                   value: MetricValue(value: 1, text: text, isEstimate: estimate, label: nil), style: style)
        }
        XCTAssertEqual(tip("41%"), tip("42%"))
        XCTAssertEqual(tip("41%", style: .group), tip("97%", style: .group))
        XCTAssertFalse(tip("41%").contains("41"), tip("41%"))
        XCTAssertEqual(tip("41%"), d.title)
    }

    func testTheRareStatesStillShowAndNothingElse() throws {
        let d = try XCTUnwrap(MetricRegistry.shared.descriptor(for: .cpuUsage))
        let estimate = WidgetRenderer.toolTip(metricID: d.id.rawValue, descriptor: d,
                                              value: MetricValue(value: 1, text: "3h", isEstimate: true, label: nil))
        XCTAssertEqual(estimate, "\(d.title) (estimate)")
        XCTAssertEqual(WidgetRenderer.toolTip(metricID: d.id.rawValue, descriptor: d, value: nil), "\(d.title): no data")
        XCTAssertEqual(WidgetRenderer.toolTip(metricID: d.id.rawValue, descriptor: d, value: nil, style: .group),
                       "\(d.title): no data\nClick for all readings")
    }

    func testAGenuinelyUnknownMetricStillSaysSo() {
        let tip = WidgetRenderer.toolTip(metricID: "no.such.metric", descriptor: nil, value: nil)
        XCTAssertTrue(tip.hasPrefix("Unknown metric"), tip)
    }
}

/// macOS 27.2 showed a status item's tooltip and then did not take it away (and did the same to another app's
/// item), so Anode's widgets carry no tooltip at all; what it said is the accessibility label instead.
final class WidgetHasNoToolTipTests: XCTestCase {

    func testAWidgetOnTheBarHasALabelAndNoToolTip() throws {
        let (defaults, name) = try TestDefaults.make(owner: "WidgetNoToolTip", test: self.name)
        let controller = MenuBarWidgetController(onClick: { _ in }, defaults: defaults, enabled: true)
        controller.setConfigs([WidgetConfig(metricID: MetricID.cpuUsage.rawValue, style: .text)])
        addTeardownBlock { controller.setEnabled(false); TestDefaults.destroy(defaults, name) }
        controller.refresh()
        let button = try XCTUnwrap(controller.statusButtons.first, "no status bar in this environment")
        XCTAssertNil(button.toolTip, "a tooltip on a status item is what macOS 27.2 left on screen")
        XCTAssertFalse((button.accessibilityLabel() ?? "").isEmpty, "the description moved to VoiceOver")
    }
}
