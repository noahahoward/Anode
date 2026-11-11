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
