import XCTest
import AppKit
@testable import AnodeApp

final class WindowLayoutPrefsTests: XCTestCase {
    private let area = CGRect(x: 0, y: 39, width: 1800, height: 1130)

    private func prefs() -> WindowPrefs { WindowPrefs(defaults: UserDefaults(suiteName: "prefs-\(UUID().uuidString)")!) }

    // ── Gaps ──

    func testNoGapChangesNothing() {
        let half = WindowGeometry.frame(for: .leftHalf, from: .zero, in: area)!
        XCTAssertEqual(WindowGeometry.placement(for: .leftHalf, from: .zero, in: area, gap: 0), half)
    }

    func testAGapIsWholeAtTheScreenEdgeAndHalfBetweenWindows() {
        let left = WindowGeometry.placement(for: .leftHalf, from: .zero, in: area, gap: 10)!
        let right = WindowGeometry.placement(for: .rightHalf, from: .zero, in: area, gap: 10)!
        XCTAssertEqual(left.minX, 10); XCTAssertEqual(left.minY, 49); XCTAssertEqual(left.maxY, area.maxY - 10)
        XCTAssertEqual(right.maxX, 1790)
        XCTAssertEqual(right.minX - left.maxX, 10, "two placed windows are one whole gap apart")
    }

    func testMaximizeHeightGapsOnlyVerticallyAndCenterNotAtAll() {
        let from = CGRect(x: 300, y: 200, width: 600, height: 400)
        let tall = WindowGeometry.placement(for: .maximizeHeight, from: from, in: area, gap: 10)!
        XCTAssertEqual(tall.minX, 300); XCTAssertEqual(tall.width, 600)
        XCTAssertEqual(tall.minY, 49)
        XCTAssertEqual(WindowGeometry.placement(for: .center, from: from, in: area, gap: 10),
                       WindowGeometry.frame(for: .center, from: from, in: area))
    }

    func testAGapNeverLeavesNothing() {
        let tiny = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(WindowGeometry.gapped(tiny, in: tiny, gap: 40), tiny)
    }

    func testRestoreAndDisplayMovesHaveNoPlacement() {
        XCTAssertNil(WindowGeometry.placement(for: .restore, from: .zero, in: area, gap: 10))
        XCTAssertNil(WindowGeometry.placement(for: .nextDisplay, from: .zero, in: area, gap: 10))
    }

    // ── Cycling ──

    func testFirstPressIsTheHalf() {
        XCTAssertEqual(WindowGeometry.nextStep(for: .leftHalf, last: nil, current: .zero), .leftHalf)
    }

    func testPressingAgainOnAWindowWhereItWasPutStepsThroughTheSizes() {
        let half = WindowGeometry.frame(for: .leftHalf, from: .zero, in: area)!
        let two = WindowGeometry.frame(for: .firstTwoThirds, from: .zero, in: area)!
        let third = WindowGeometry.frame(for: .firstThird, from: .zero, in: area)!
        XCTAssertEqual(WindowGeometry.nextStep(for: .leftHalf, last: .init(pressed: .leftHalf, step: .leftHalf, frame: half), current: half), .firstTwoThirds)
        XCTAssertEqual(WindowGeometry.nextStep(for: .leftHalf, last: .init(pressed: .leftHalf, step: .firstTwoThirds, frame: two), current: two), .firstThird)
        XCTAssertEqual(WindowGeometry.nextStep(for: .leftHalf, last: .init(pressed: .leftHalf, step: .firstThird, frame: third), current: third), .leftHalf,
                       "it wraps round")
    }

    func testAMovedWindowOrAnotherActionStartsOver() {
        let half = WindowGeometry.frame(for: .leftHalf, from: .zero, in: area)!
        let last = WindowGeometry.LastPlacement(pressed: .leftHalf, step: .leftHalf, frame: half)
        XCTAssertEqual(WindowGeometry.nextStep(for: .leftHalf, last: last, current: half.offsetBy(dx: 40, dy: 0)), .leftHalf, "moved since")
        XCTAssertEqual(WindowGeometry.nextStep(for: .rightHalf, last: last, current: half), .rightHalf, "a different action")
        XCTAssertEqual(WindowGeometry.nextStep(for: .leftHalf, last: .init(pressed: .firstThird, step: .firstThird, frame: half), current: half), .leftHalf)
    }

    func testOnlyTheHalvesCycleAndTheRightOneGoesTheOtherWay() {
        XCTAssertEqual(WindowGeometry.cycle(for: .rightHalf), [.rightHalf, .lastTwoThirds, .lastThird])
        XCTAssertNil(WindowGeometry.cycle(for: .maximize))
        XCTAssertEqual(WindowGeometry.nextStep(for: .maximize, last: nil, current: .zero), .maximize)
    }

    // ── The zone map ──

    func testZonesGiveTheirDefaultActionsUntilChanged() {
        let map = SnapZoneMap()
        XCTAssertEqual(map.action(for: .left), .leftHalf)
        XCTAssertEqual(map.action(for: .top), .maximize)
        XCTAssertEqual(map.action(for: .bottomCenter), .centerThird)
        XCTAssertTrue(map.isDefault)
    }

    func testClickingAZoneGivesItTheActionAndClickingAgainTurnsItOff() {
        var map = SnapZoneMap()
        map.toggle(.top, for: .topHalf)
        XCTAssertEqual(map.action(for: .top), .topHalf)
        XCTAssertEqual(map.zones(for: .topHalf), [.top])
        map.toggle(.top, for: .topHalf)
        XCTAssertNil(map.action(for: .top), "already its: it loses it")
        map.toggle(.top, for: .maximize)
        XCTAssertTrue(map.isDefault, "back to the default is not a change worth keeping")
    }

    func testAZoneCanHaveNoActionAndOnlyRectangleActionsAreAccepted() {
        var map = SnapZoneMap()
        map.set(nil, for: .left)
        XCTAssertNil(map.action(for: .left))
        let back = SnapZoneMap(stored: map.stored)
        XCTAssertEqual(back, map, "survives being stored")
        XCTAssertNil(SnapZoneMap(stored: ["left": "restore"]).overrides[.left] ?? nil, "restore has no outline to show")
        XCTAssertEqual(SnapZoneMap(stored: ["left": "restore"]).action(for: .left), .leftHalf)
        XCTAssertEqual(SnapZoneMap(stored: ["nonsense": "maximize"]), SnapZoneMap())
    }

    func testEveryZoneKeyRoundTrips() {
        for z in SnapZone.allCases { XCTAssertEqual(SnapZone(key: z.key), z) }
        XCTAssertEqual(SnapZone.allCases.count, 10)
    }

    // ── The ring of cells ──

    func testTheRingBelongsToTheZonesTheWayTheyAreLaidOut() {
        let c = ZoneLayout.cols, r = ZoneLayout.rows
        XCTAssertEqual(ZoneLayout.zone(col: 0, row: 0), .topLeft)
        XCTAssertEqual(ZoneLayout.zone(col: 1, row: 0), .topLeft)
        XCTAssertEqual(ZoneLayout.zone(col: 0, row: 1), .topLeft)
        XCTAssertEqual(ZoneLayout.zone(col: c - 1, row: 0), .topRight)
        XCTAssertEqual(ZoneLayout.zone(col: 0, row: r - 1), .bottomLeft)
        XCTAssertEqual(ZoneLayout.zone(col: c - 1, row: r - 1), .bottomRight)
        XCTAssertEqual(ZoneLayout.zone(col: 0, row: 5), .left)
        XCTAssertEqual(ZoneLayout.zone(col: c - 1, row: 5), .right)
        XCTAssertEqual(ZoneLayout.zone(col: 8, row: 0), .top)
        XCTAssertEqual(ZoneLayout.zone(col: 3, row: r - 1), .bottomFirst)
        XCTAssertEqual(ZoneLayout.zone(col: 9, row: r - 1), .bottomCenter)
        XCTAssertEqual(ZoneLayout.zone(col: 15, row: r - 1), .bottomLast)
        XCTAssertNil(ZoneLayout.zone(col: 5, row: 5), "inside the ring")
        XCTAssertNil(ZoneLayout.zone(col: -1, row: 0))
        let all = Set((0..<c).flatMap { col in (0..<r).compactMap { ZoneLayout.zone(col: col, row: $0) } })
        XCTAssertEqual(all.count, 10, "every zone can be clicked")
    }

    func testTheRegionPreviewMatchesWhatTheActionDoes() {
        XCTAssertEqual(RegionGridView.region(for: .leftHalf), CGRect(x: 0, y: 0, width: 9, height: 12))
        XCTAssertEqual(RegionGridView.region(for: .topRight), CGRect(x: 9, y: 0, width: 9, height: 6))
        XCTAssertEqual(RegionGridView.region(for: .firstTwoThirds), CGRect(x: 0, y: 0, width: 12, height: 12))
        XCTAssertNil(RegionGridView.region(for: .restore))
    }

    // ── The preferences ──

    func testPreferencesDefaultAndPersist() {
        let p = prefs()
        XCTAssertEqual(p.gap, 0); XCTAssertTrue(p.cycles); XCTAssertEqual(p.snapModifier, .none); XCTAssertTrue(p.zoneMap.isDefault)
        p.gap = 12; p.cycles = false; p.snapModifier = .shift
        var map = p.zoneMap; map.set(nil, for: .left); p.zoneMap = map
        XCTAssertEqual(p.gap, 12); XCTAssertFalse(p.cycles); XCTAssertEqual(p.snapModifier, .shift)
        XCTAssertNil(p.zoneMap.action(for: .left))
        p.gap = 500
        XCTAssertEqual(p.gap, WindowPrefs.maxGap, "capped")
        p.zoneMap = SnapZoneMap()
        XCTAssertTrue(p.zoneMap.isDefault)
    }

    func testTheSnapModifierMustBeHeldWhenOneIsChosen() {
        XCTAssertTrue(SnapModifier.none.isSatisfied(by: []))
        XCTAssertFalse(SnapModifier.shift.isSatisfied(by: []))
        XCTAssertTrue(SnapModifier.shift.isSatisfied(by: [.maskShift]))
        XCTAssertTrue(SnapModifier.option.isSatisfied(by: [.maskAlternate, .maskShift]))
        XCTAssertFalse(SnapModifier.command.isSatisfied(by: [.maskAlternate]))
    }
}
