import XCTest
@testable import PowerKit

/// When the menu bar hider may cover anything, and when the pill closes.
final class HiderPolicyTests: XCTestCase {

    private func decide(enabled: Bool = true, trusted: Bool = true, readable: Bool = true, fullScreen: Bool = false,
                        since: TimeInterval = 60, onScreen: Bool = true, chevronOnBar: Bool = true) -> HiderDecision {
        HiderPolicy.decide(enabled: enabled, accessibilityTrusted: trusted, layoutReadable: readable, fullScreen: fullScreen,
                           secondsSinceSpaceOrDisplayChange: since, itemsOnThisScreen: onScreen, chevronOnBar: chevronOnBar)
    }

    func testCollapsedWhenAllClear() {
        XCTAssertEqual(decide(), .collapsed)
    }

    func testRefusalOrder() {
        XCTAssertEqual(decide(enabled: false, trusted: false, readable: false, fullScreen: true, since: 0, onScreen: false),
                       .standDown(.disabled))
        XCTAssertEqual(decide(trusted: false, readable: false, fullScreen: true, since: 0, onScreen: false),
                       .standDown(.noAccessibility))
        XCTAssertEqual(decide(readable: false, fullScreen: true, since: 0, onScreen: false), .standDown(.layoutUnreadable))
        XCTAssertEqual(decide(fullScreen: true, since: 0, onScreen: false), .standDown(.fullScreen))
        XCTAssertEqual(decide(since: 0, onScreen: false), .standDown(.settling))
        XCTAssertEqual(decide(onScreen: false, chevronOnBar: false), .standDown(.itemsNotOnThisScreen))
        XCTAssertEqual(decide(chevronOnBar: false), .standDown(.chevronOffBar))
    }

    func testSettlingUnderOneSecond() {
        XCTAssertEqual(decide(since: 0.99), .standDown(.settling))
        XCTAssertEqual(decide(since: 1.0), .collapsed)
    }

    // ── The pill ────────────────────────────────────────────────────────────

    private let t0 = Date(timeIntervalSince1970: 1_000)

    func testToggleOpensThenCloses() {
        var s = PillState()
        XCTAssertFalse(s.isOpen)
        s.toggle(now: t0, autoClose: 10)
        XCTAssertTrue(s.isOpen)
        s.toggle(now: t0.addingTimeInterval(1), autoClose: 10)
        XCTAssertFalse(s.isOpen)
        XCTAssertNil(s.closeAt)
    }

    func testAutoCloseAfterSeconds() {
        var s = PillState()
        s.toggle(now: t0, autoClose: 10)
        s.tick(now: t0.addingTimeInterval(9.9))
        XCTAssertTrue(s.isOpen)
        s.tick(now: t0.addingTimeInterval(10))
        XCTAssertFalse(s.isOpen)
    }

    func testNeverStaysOpen() {
        var s = PillState()
        s.toggle(now: t0, autoClose: 0)
        XCTAssertNil(s.closeAt)
        s.tick(now: t0.addingTimeInterval(100_000))
        XCTAssertTrue(s.isOpen)
    }

    func testScreenChangeClosesPill() {
        var s = PillState()
        s.toggle(now: t0, autoClose: 0)
        s.screenParametersChanged()
        XCTAssertFalse(s.isOpen)
    }

    func testExplicitCloseClears() {
        var s = PillState()
        s.toggle(now: t0, autoClose: 5)
        s.close()
        XCTAssertEqual(s, PillState())
    }
}
