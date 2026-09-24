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

    func testAGenuinelyUnknownMetricStillSaysSo() {
        let tip = WidgetRenderer.toolTip(metricID: "no.such.metric", descriptor: nil, value: nil)
        XCTAssertTrue(tip.hasPrefix("Unknown metric"), tip)
    }
}
