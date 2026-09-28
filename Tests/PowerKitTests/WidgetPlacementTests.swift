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

    func testPlacementClassification() {
        XCTAssertEqual(C.placement(shown: 4, total: 4), .allShown)
        XCTAssertEqual(C.placement(shown: 0, total: 4), .noneShown)
        XCTAssertEqual(C.placement(shown: 1, total: 4), .partlyHidden(shown: 1, total: 4))
        XCTAssertEqual(C.placement(shown: 0, total: 0), .unknown,
                       "nothing to show is not the same as nothing shown")
    }

    /// Only `.noneShown` may take the menu bar away as the app's door: a
    /// partial hide still leaves something to click.
    func testOnlyNothingShownMakesTheMenuBarUnreachable() {
        XCTAssertNotEqual(C.Placement.partlyHidden(shown: 1, total: 3), .noneShown)
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

    /// The single item carries its reading, so it has to be wider than the bare glyph.
    func testTheHeadlineWidensTheGroupGlyph() {
        let bare = WidgetRenderer.groupImage()
        let withReading = WidgetRenderer.groupImage(headline: "12%/h")
        XCTAssertGreaterThan(withReading.size.width, bare.size.width + 10)
    }
}
