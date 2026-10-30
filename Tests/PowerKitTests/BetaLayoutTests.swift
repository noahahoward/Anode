import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

final class BetaLayoutTests: XCTestCase {
    typealias C = BetaFeaturesWindowController

    func testSectionsStayInOrderAndEveryOneIsPlacedOnce() {
        let groups = C.partition(heights: [100, 300, 200, 150, 250, 120], into: 3, spacing: 20)
        XCTAssertEqual(groups.flatMap { $0 }, [0, 1, 2, 3, 4, 5], "read down each column, then across")
        XCTAssertEqual(groups.count, 3)
        XCTAssertTrue(groups.allSatisfy { !$0.isEmpty })
    }

    func testTheTallestColumnIsAsShortAsItCanBe() {
        let heights: [CGFloat] = [100, 300, 200, 150, 250, 120]
        func tallest(_ g: [[Int]]) -> CGFloat { g.map { run in run.map { heights[$0] }.reduce(0, +) + 20 * CGFloat(run.count - 1) }.max()! }
        let best = C.partition(heights: heights, into: 3, spacing: 20)
        // No other way of cutting six sections into three runs beats it.
        var other: CGFloat = .infinity
        for a in 1..<5 { for b in (a + 1)..<6 {
            other = min(other, tallest([Array(0..<a), Array(a..<b), Array(b..<6)]))
        } }
        XCTAssertEqual(tallest(best), other, accuracy: 0.001)
    }

    func testEdgeCases() {
        XCTAssertEqual(C.partition(heights: [], into: 3, spacing: 10), [])
        XCTAssertEqual(C.partition(heights: [50], into: 3, spacing: 10), [[0]], "never more columns than sections")
        XCTAssertEqual(C.partition(heights: [50, 60], into: 1, spacing: 10), [[0, 1]])
    }

    func testTheFewestColumnsThatFitAreUsed() {
        let heights: [CGFloat] = [200, 300, 250, 300, 350, 250]       // 1650 plus gaps: too tall for 900
        let spacing: CGFloat = 22
        XCTAssertEqual(C.columnCount(heights: heights, available: 4000, maxWidth: 2000, spacing: spacing), 1, "it all fits as it is")
        let two = C.columnCount(heights: heights, available: 1000, maxWidth: 2000, spacing: spacing)
        XCTAssertEqual(two, 2)
        XCTAssertEqual(C.columnCount(heights: heights, available: 700, maxWidth: 2000, spacing: spacing), 3)
    }

    func testANarrowScreenLimitsTheColumns() {
        let heights: [CGFloat] = Array(repeating: 400, count: 6)
        // 700 wide only holds one 440 pt column: it scrolls instead of widening past the screen.
        XCTAssertEqual(C.columnCount(heights: heights, available: 500, maxWidth: 700, spacing: 22), 1)
        XCTAssertEqual(C.columnCount(heights: heights, available: 500, maxWidth: 1000, spacing: 22), 2)
    }

    /// The reported problem: with every feature, the window was taller than the screen.
    func testTheRealWindowFitsTheScreen() {
        _ = NSApplication.shared
        let c = BetaFeaturesWindowController()
        let screen = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let frame = c.window!.frame
        XCTAssertLessThanOrEqual(frame.height, screen.height, "no taller than the screen")
        XCTAssertLessThanOrEqual(frame.width, screen.width, "no wider than the screen")
        XCTAssertGreaterThan(frame.width, BetaFeaturesWindowController.columnWidth + 40, "wider than one column: width over height")
    }
}
