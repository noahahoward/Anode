import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// Widgets that exist and are never seen.
///
/// On a narrow menu bar (a 13" MacBook Neo, say) macOS packs status items right
/// to left and silently drops whatever reaches the left end — no overflow menu,
/// no error, and every property the app set still reads healthy. The only
/// witness is the frame of the window AppKit gave the button. These pin the rule
/// that reads that witness, and the ladder the controller squeezes down when it
/// has to.
final class WidgetPlacementTests: XCTestCase {

    private typealias C = MenuBarWidgetController
    /// A 1280-point laptop screen with its menu bar at the top.
    private let laptop = C.ScreenGeometry(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))

    private func item(x: CGFloat, width: CGFloat = 40) -> NSRect {
        NSRect(x: x, y: 776, width: width, height: 24)
    }

    func testAnItemInTheBarIsPlaced() {
        XCTAssertTrue(C.isPlaced(item(x: 900), on: [laptop]))
    }

    /// WIDGET-BUG.md: created, sized, `isVisible`, and never laid out.
    func testAZeroHeightWindowWasNeverPlaced() {
        XCTAssertFalse(C.isPlaced(NSRect(x: 0, y: 0, width: 40, height: 0), on: [laptop]))
        XCTAssertFalse(C.isPlaced(nil, on: [laptop]), "no window at all is not placed either")
    }

    /// Where a dropped item ends up: off the left edge, or nowhere near a screen.
    func testAnItemOffEveryScreenIsNotPlaced() {
        XCTAssertFalse(C.isPlaced(NSRect(x: -1, y: 1157, width: 40, height: 24), on: [laptop]))
        XCTAssertFalse(C.isPlaced(item(x: -30), on: [laptop]),
                       "an item half off the edge has been pushed out of the bar")
    }

    /// A second display counts: an item on either screen is an item on screen.
    func testAnItemOnASecondScreenIsPlaced() {
        let external = C.ScreenGeometry(frame: NSRect(x: 1280, y: 0, width: 1920, height: 1080))
        XCTAssertTrue(C.isPlaced(NSRect(x: 2800, y: 1056, width: 40, height: 24),
                                 on: [laptop, external]))
    }

    /// Behind the camera housing is off screen as far as anyone can see.
    func testAnItemBehindTheNotchIsNotPlaced() {
        let notched = C.ScreenGeometry(frame: NSRect(x: 0, y: 0, width: 1512, height: 982),
                                       notch: 661...851)
        XCTAssertFalse(C.isPlaced(NSRect(x: 820, y: 958, width: 40, height: 24), on: [notched]))
        XCTAssertTrue(C.isPlaced(NSRect(x: 900, y: 958, width: 40, height: 24), on: [notched]))
    }

    /// Measured on macOS 27: an item that does not fit is parked below the
    /// screen at (0, -h), full height. Horizontally that is on screen, so it is
    /// the vertical rule that has to catch it.
    func testAnItemParkedBelowTheScreenIsNotPlaced() {
        XCTAssertFalse(C.isPlaced(NSRect(x: 0, y: -24, width: 40, height: 24), on: [laptop]))
    }

    /// An auto-hidden menu bar may slide its items up past the top edge while
    /// they are still in the bar. They count; the old gate on
    /// `NSMenu.menuBarVisible()` meant such a Mac was never looked at.
    func testAnItemInASlidUpAutoHiddenBarIsPlaced() {
        XCTAssertTrue(C.isPlaced(NSRect(x: 900, y: 800, width: 40, height: 24), on: [laptop]))
    }

    private func states(_ frames: [NSRect?], visible: Bool = true) -> [C.ItemState] {
        C.states(frames: frames, windowsVisible: frames.map { _ in visible }, on: [laptop])
    }

    func testItemStates() {
        XCTAssertEqual(states([item(x: 900)]), [.shown])
        XCTAssertEqual(states([NSRect(x: 0, y: -24, width: 40, height: 24)]), [.parked])
        XCTAssertEqual(states([NSRect(x: 0, y: 0, width: 40, height: 0)]), [.unplaced])
        XCTAssertEqual(states([nil]), [.unplaced], "no window at all was never placed")
        XCTAssertEqual(states([item(x: 900)], visible: false), [.parked],
                       "a window that is ordered out is not showing, wherever it is")
    }

    /// Two items of one app stacked on one frame: the last slot before the
    /// frontmost app's menus, fought over. Only one of them can be seen.
    func testAnItemStackedOnItsNeighbourIsParked() {
        XCTAssertEqual(states([item(x: 397), item(x: 397), item(x: 500)]),
                       [.shown, .parked, .shown])
        XCTAssertEqual(states([item(x: 400), item(x: 440)]), [.shown, .shown],
                       "neighbours that merely touch are both in the bar")
    }

    func testPlacementClassification() {
        XCTAssertEqual(C.placement([.shown, .shown]), .allShown)
        XCTAssertEqual(C.placement([.shown, .parked, .unplaced]),
                       .partlyHidden(shown: 1, total: 3))
        XCTAssertEqual(C.placement([.parked, .parked]), .noneShown)
        XCTAssertEqual(C.placement([.parked, .unplaced]), .noneShown,
                       "any item laid out off screen means the bar is full")
        XCTAssertEqual(C.placement([]), .unknown,
                       "nothing to show is not the same as nothing shown")
    }

    /// Every item zero-height is macOS withholding the app — System Settings ›
    /// Menu Bar › Allow in the Menu Bar — which is what a MacBook Neo showed.
    func testEveryItemUnplacedIsNotAllowed() {
        XCTAssertEqual(C.placement([.unplaced, .unplaced, .unplaced]), .notAllowed)
    }

    /// Squeezing is for a full bar. A switched-off app squeezed to one item
    /// would come back one item wide when switched on again.
    func testOnlyAFullBarIsSqueezed() {
        XCTAssertTrue(C.shouldSqueeze([.shown, .parked]))
        XCTAssertFalse(C.shouldSqueeze([.unplaced, .unplaced]))
        XCTAssertFalse(C.shouldSqueeze([.shown, .shown]))
    }

    /// Only nothing-visible takes the menu bar away as the app's door: a
    /// partial hide still leaves something to click.
    func testOnlyNothingShownMakesTheMenuBarUnreachable() {
        XCTAssertTrue(C.Placement.partlyHidden(shown: 1, total: 3).isReachable)
        XCTAssertTrue(C.Placement.unknown.isReachable, "every launch passes through unknown")
        XCTAssertFalse(C.Placement.noneShown.isReachable)
        XCTAssertFalse(C.Placement.notAllowed.isReachable)
    }

    /// Each unreachable state names its own cause and its own remedy.
    func testTheSettingsNoteNamesTheCause() {
        let off = C.Placement.notAllowed.settingsNote ?? ""
        let full = C.Placement.noneShown.settingsNote ?? ""
        XCTAssertTrue(off.contains("Allow in the Menu Bar"))
        XCTAssertFalse(full.contains("Allow in the Menu Bar"))
        XCTAssertNil(C.Placement.allShown.settingsNote)
    }

    // ── The ladder ────────────────────────────────────────────────────────────

    private let configs = [
        WidgetConfig(metricID: MetricID.batteryDrain.rawValue, style: .textWithLabel),
        WidgetConfig(metricID: MetricID.cpuUsage.rawValue, style: .textWithLabel, enabled: false),
        WidgetConfig(metricID: MetricID.memoryUsage.rawValue, style: .sparkline),
        WidgetConfig(metricID: MetricID.groupPlaceholder.rawValue, style: .group),
    ]

    func testFullIsTheArrangementAsConfigured() {
        XCTAssertEqual(C.effectiveConfigs(configs, density: .full),
                       configs.filter(\.enabled))
    }

    func testCompactDropsLabelsAndNothingElse() {
        let compact = C.effectiveConfigs(configs, density: .compact)
        XCTAssertEqual(compact.map(\.metricID), configs.filter(\.enabled).map(\.metricID))
        XCTAssertFalse(compact.contains { $0.style == .textWithLabel })
        XCTAssertEqual(compact[1].style, .sparkline, "only labelled text is shortened")
    }

    /// One item, carrying the first real reading, opening the full panel.
    func testSingleIsOneGroupItemCarryingTheHeadline() {
        let single = C.effectiveConfigs(configs, density: .single)
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single[0].style, .group)
        XCTAssertEqual(single[0].metricID, MetricID.batteryDrain.rawValue)
    }

    func testSingleWithOnlyTheGroupIsThePlainGroup() {
        let onlyGroup = [WidgetConfig(metricID: MetricID.groupPlaceholder.rawValue, style: .group)]
        XCTAssertEqual(C.effectiveConfigs(onlyGroup, density: .single).first?.metricID,
                       MetricID.groupPlaceholder.rawValue)
    }

    func testTheLadderEnds() {
        XCTAssertEqual(C.Density.full.tighter, .compact)
        XCTAssertEqual(C.Density.compact.tighter, .single)
        XCTAssertNil(C.Density.single.tighter, "nothing is narrower than one item")
    }

    /// The single item's tooltip names its reading and says what a click does,
    /// rather than calling a real metric an unknown one.
    func testTheSingleItemToolTip() {
        let tip = WidgetRenderer.toolTip(metricID: MetricID.batteryDrain.rawValue,
                                         descriptor: nil, value: nil, style: .group)
        XCTAssertFalse(tip.contains("Unknown"))
        XCTAssertTrue(tip.contains("all readings"))
    }

    /// Compact exists to be narrower. The label is stacked above the value, so
    /// dropping it alone narrowed nothing, and a 12 pt value made a squeezed bar
    /// WIDER than the full one on a MacBook Neo.
    func testCompactIsNarrowerThanTheLabelledWidget() {
        for value in ["12.3%/h", "100%", "87\u{00B0}C", "1.9 GB", "2h 58m"] {
            let full = WidgetRenderer.textImage(label: "CPU\u{00B0}", value: value).size.width
                + 16   // AppKit's own padding on a variable-length item
            let compact = WidgetRenderer.textImage(label: nil, value: value, compact: true)
                .size.width + C.compactPadding
            XCTAssertLessThan(compact, full - 8, "compact \(value) saves too little")
        }
    }

    /// The single item carries its reading, so it has to be wider than the bare glyph.
    func testTheHeadlineWidensTheGroupGlyph() {
        let bare = WidgetRenderer.groupImage()
        let withReading = WidgetRenderer.groupImage(headline: "12%/h")
        XCTAssertGreaterThan(withReading.size.width, bare.size.width + 10)
    }
}
