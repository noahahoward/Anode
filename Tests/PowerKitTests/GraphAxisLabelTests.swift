import XCTest
@testable import PowerKit

/// The x axis must name instants once the view is panned off "now".
///
/// The bug: tick labels counted back from the RIGHT EDGE of the visible domain
/// ("now", "-20s", "-40s"). That is correct for a live chart and wrong the
/// moment the view is panned, because the right edge moves with the pan — so
/// every label kept reading the same thing while the data slid underneath.
/// Reported as "when I pan the graph the bottom doesn't move with it".
///
/// These test the RULE rather than the view, because the drawing lives in the
/// app target and needs a real graphics context. The rule is: relative labels
/// only while the right edge really is now, and the liveness tolerance scales
/// with the span.
final class GraphAxisLabelTests: XCTestCase {

    /// Mirrors `HistoryGraphView`'s liveness test.
    private func liveEdge(edgeAgo: TimeInterval, span: Double) -> Bool {
        edgeAgo <= max(5, span * 0.02)
    }

    func testALiveEdgeKeepsRelativeLabels() {
        XCTAssertTrue(liveEdge(edgeAgo: 0, span: 3600))
        XCTAssertTrue(liveEdge(edgeAgo: 2, span: 60), "tick jitter is still live")
    }

    /// A 7-day chart whose newest sample is four minutes old is still live; a
    /// 60-second chart four minutes off the edge plainly is not.
    func testToleranceScalesWithSpan() {
        XCTAssertTrue(liveEdge(edgeAgo: 240, span: 7 * 86_400))
        XCTAssertFalse(liveEdge(edgeAgo: 240, span: 60))
    }

    /// The floor stops a 1 h view flipping label styles on ordinary jitter,
    /// where 2% would be only 72 seconds... and 5 s is the floor that matters
    /// for short spans.
    func testAFloorProtectsShortSpans() {
        XCTAssertTrue(liveEdge(edgeAgo: 4, span: 10), "2% of 10s is 0.2s; the floor rules")
        XCTAssertFalse(liveEdge(edgeAgo: 6, span: 10))
    }

    /// Panned well into the past: absolute labels, always.
    func testPannedIntoHistoryIsNotLive() {
        XCTAssertFalse(liveEdge(edgeAgo: 3600, span: 3600))
        XCTAssertFalse(liveEdge(edgeAgo: 86_400, span: 7 * 86_400))
    }
}
