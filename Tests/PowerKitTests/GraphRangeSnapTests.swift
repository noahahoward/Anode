import XCTest
@testable import PowerKit
@testable import AnodeApp

/// Switching subjects must not leave the graph drawing the previous subject's
/// time domain.
///
/// ## The bug
/// Reported from the field: the Fans tab drew a SIX HOUR axis (09:25-15:25)
/// with no fan line at all and a single temperature dot pinned to the right
/// edge.
///
/// `BottomContext.ranges` offers `.fans` and `.sensors` one range — 3600 —
/// because the SMC sweep is gated on their tab being open and there is no
/// stored history to draw. The context switch correctly snapped `graphRange`
/// back to 3600 and highlighted the 1H chip. What it did NOT do was clear
/// `HistoryGraphView.timeDomain`, because that only ever happened inside the
/// range picker's `onSelect`, and `GraphRanges.select(seconds:)` deliberately
/// does not fire `onSelect` — it only moves the highlight.
///
/// So the graph kept the 6 h domain set by the previous subject, and honoured
/// it: "An explicit domain wins over the data's own extent, so an empty stretch
/// of history stays empty on screen instead of silently rescaling the axis to
/// whatever few points happen to exist." That rule is right. It was being fed a
/// domain from a different subject.
///
/// The result reads as a broken graph, and the one thing it could not be
/// mistaken for is what it actually was: a correct axis over the wrong window.
final class GraphRangeSnapTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// The subjects with no stored history offer 1H and only 1H.
    func testSessionOnlySubjectsOfferOneRange() {
        for c in [BottomContext.fans, .sensors] {
            XCTAssertEqual(c.ranges, [3600], "\(c) has no history to draw")
        }
    }

    /// A range the new subject does not offer must be replaced by one it does.
    func testAnUnofferedRangeSnapsBack() {
        for c in [BottomContext.fans, .sensors] {
            for previous: TimeInterval in [6 * 3600, 24 * 3600, 7 * 24 * 3600] {
                XCTAssertEqual(AppDelegate.snappedRange(for: c, current: previous), 3600,
                               "\(c) cannot draw \(previous)s")
            }
        }
        // A range the subject DOES offer is left alone — snapping every switch
        // would throw away a deliberate choice on every tab change.
        XCTAssertNil(AppDelegate.snappedRange(for: .battery, current: 6 * 3600))
        XCTAssertNil(AppDelegate.snappedRange(for: .fans, current: 3600))
    }

    /// 1H is a LIVE strip chart, which means no explicit domain at all — the
    /// axis follows the data. A non-nil domain here is the bug.
    func testTheLiveRangeHasNoExplicitDomain() {
        XCTAssertNil(AppDelegate.graphDomain(for: 3600, now: now))
        XCTAssertNil(AppDelegate.graphDomain(for: 600, now: now))
        let six = AppDelegate.graphDomain(for: 6 * 3600, now: now)
        XCTAssertEqual(six?.end, now)
        XCTAssertEqual(six?.start, now.addingTimeInterval(-6 * 3600))
    }

    /// THE REGRESSION, stated as the invariant rather than as the one path that
    /// broke: after switching to ANY subject from ANY previously-chosen range,
    /// the domain the graph is left holding must be one that subject can fill.
    ///
    /// Before the fix, `.fans` and `.sensors` failed this for every range above
    /// an hour — which is every range the battery graph offers but one.
    func testNoSubjectIsEverLeftHoldingAWindowItCannotFill() {
        let everyRange: [TimeInterval] = [3600, 6 * 3600, 24 * 3600, 7 * 24 * 3600]
        for c in BottomContext.allCases {
            for previous in everyRange {
                let effective = AppDelegate.snappedRange(for: c, current: previous) ?? previous
                XCTAssertTrue(c.ranges.contains(effective),
                              "\(c) settled on \(effective)s, which it does not offer")
                guard let domain = AppDelegate.graphDomain(for: effective, now: now) else {
                    continue     // live chart, follows its own data — always safe
                }
                let span = domain.end.timeIntervalSince(domain.start)
                XCTAssertLessThanOrEqual(span, c.ranges.max() ?? 3600,
                                         "\(c) would draw a \(span / 3600) h axis over "
                                         + "at most \((c.ranges.max() ?? 0) / 3600) h of data")
            }
        }
    }

    /// The exact reported journey: Battery at 6H, then click Fans.
    func testTheReportedPathLeavesALiveAxis() {
        let snapped = AppDelegate.snappedRange(for: .fans, current: 6 * 3600)
        XCTAssertEqual(snapped, 3600)
        XCTAssertNil(AppDelegate.graphDomain(for: snapped!, now: now),
                     "the fan graph must follow its own buffer, not the six hours "
                     + "the battery tab was showing")
    }
}
