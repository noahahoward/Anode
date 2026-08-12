import AppKit
import XCTest
@testable import BetterStatsApp
@testable import PowerKit

/// The rail became icons, which costs two things unless they are asserted: the
/// glyph has to exist on the running OS, and the NAME of each destination has to
/// survive somewhere a user — and the menu-consistency test — can still read it.
final class SidebarIconTests: XCTestCase {

    /// A symbol that does not resolve renders as nothing at all, and the rail is now
    /// the only way to navigate. Every name used is from SF Symbols 1 or 2, below
    /// this app's macOS 13 floor, so a failure here means a name was mistyped or a
    /// symbol was deprecated out from under it.
    func testEveryTabHasAGlyphThisSystemCanDraw() {
        for lens in SidebarView.Lens.allCases {
            XCTAssertNotNil(
                NSImage(systemSymbolName: lens.symbolName, accessibilityDescription: nil),
                "\(lens.rawValue) would draw an empty rail row")
        }
    }

    func testEveryTabUsesADistinctGlyph() {
        let names = SidebarView.Lens.allCases.map(\.symbolName)
        XCTAssertEqual(Set(names).count, names.count,
                       "two tabs draw the same icon, so the rail cannot be read")
    }

    /// An icon rail must not cost the name of the thing it navigates to. The
    /// tooltip is the only label a user gets, and it carries the title, whatever is
    /// being sampled, and one line on what the tab holds.
    func testEveryTabExplainsItselfOnHover() {
        for lens in SidebarView.Lens.allCases {
            XCTAssertGreaterThan(lens.summary.count, 20, lens.rawValue)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// What each tab is allowed to make the sampler do.
///
/// Idle cost is the property this app is built around, and the Resources tab is the
/// first thing in it that genuinely wants every subsystem at once. The rule that
/// keeps that from becoming everyone's bill is that a tab declares its own needs
/// and the sampler asks for exactly those.
final class LensSamplingNeedsTests: XCTestCase {

    /// The expensive one. `Sensors.inventory()` walks thousands of SMC keys —
    /// measured at 88 ms wall / 9.1 ms CPU a sweep, and enough to double idle CPU
    /// (0.375% → 0.727%) when it was taken unconditionally. Only the three tabs that
    /// display a temperature or a fan speed may ask for it.
    func testOnlyTheTabsThatShowTemperaturesAskForTheSMC() {
        let wanting = SidebarView.Lens.allCases
            .filter { $0.needs.contains(.sensors) }
            .map(\.rawValue)
            .sorted()
        XCTAssertEqual(wanting, ["fans", "resources", "sensors"])
    }

    /// The process table comes from the per-process sweep, not from SystemMetrics.
    /// Sitting on it must cost nothing from this side at all.
    func testTheProcessTableAsksForNothing() {
        XCTAssertEqual(SidebarView.Lens.processes.needs, [])
    }

    /// Resources is the tab that shows all of it, so it is the tab that asks for
    /// all of it — and it is the ONLY one, which is what the gate is for.
    func testResourcesIsTheOnlyTabThatAsksForEverything() {
        XCTAssertEqual(SidebarView.Lens.resources.needs, .all)
        for lens in SidebarView.Lens.allCases where lens != .resources {
            XCTAssertNotEqual(lens.needs, .all, lens.rawValue)
        }
    }

    func testTheNetworkTabAsksForNetworkAndNothingElse() {
        XCTAssertEqual(SidebarView.Lens.network.needs, .network)
    }

    /// Clicking a menu bar widget opens the window on the tab that explains that
    /// number — and now that a tab decides what is sampled, "explains" has to mean
    /// "is reading it". A widget that navigated to a tab which does not ask for its
    /// subsystem would land the user on a blank reading, which is worse than not
    /// navigating at all.
    func testAWidgetNeverLandsOnATabThatIsNotSamplingIt() {
        let required: [(MetricID, SystemMetrics.Needs)] = [
            (.cpuUsage, .cpu), (.memoryUsage, .memory), (.gpuUsage, .gpu),
            (.diskRead, .disk), (.diskWrite, .disk), (.diskActivity, .disk),
            (.networkDown, .network), (.networkUp, .network),
            (.networkThroughput, .network),
            (.cpuTemperature, .sensors), (.gpuTemperature, .sensors),
            (.fanSpeed, .sensors),
        ]
        for (metric, need) in required {
            let lens = AppDelegate.lens(forWidget: metric)
            XCTAssertNotNil(lens, "\(metric.rawValue) navigates nowhere")
            XCTAssertTrue(lens?.needs.contains(need) ?? false,
                          "\(metric.rawValue) opens \(lens?.rawValue ?? "nothing"), "
                        + "which does not sample it")
        }
    }

    /// The battery family has no whole-machine utilisation behind it — it is served
    /// by the monitor, not by SystemMetrics — so it goes to the table that itemises
    /// it, and the ledger, glance card and graph beneath every tab do the rest.
    func testBatteryWidgetsOpenTheProcessTable() {
        XCTAssertEqual(AppDelegate.lens(forWidget: .batteryDrain), .processes)
        XCTAssertEqual(AppDelegate.lens(forWidget: .batteryTimeLeft), .processes)
        XCTAssertNil(AppDelegate.lens(forWidget: .samplerDrops),
                     "sampler health is not a reading of the machine")
        XCTAssertNil(AppDelegate.lens(forWidget: .groupPlaceholder))
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// The rail's motion, which is the one animation in this app that is not a
/// response to the user — so it is the one with rules.
final class FanSpinTests: XCTestCase {

    override func setUp() { _ = NSApplication.shared }

    /// A parked fan does not spin the glyph.
    ///
    /// Fans on this hardware rest at 0 rpm when cool, and that is a reading worth
    /// seeing at a glance. A glyph that turned regardless would be decoration, and
    /// decoration that never stops is a heartbeat.
    func testAParkedFanLeavesTheGlyphStill() {
        let rail = SidebarView()
        rail.setFanSpin(rpm: 0)
        XCTAssertFalse(rail.isFanGlyphSpinning)
    }

    /// And a turning fan turns it.
    func testATurningFanSpinsTheGlyph() {
        let rail = SidebarView()
        rail.setFanSpin(rpm: 2400)
        XCTAssertTrue(rail.isFanGlyphSpinning)
        // Stopping puts it back.
        rail.setFanSpin(rpm: 0)
        XCTAssertFalse(rail.isFanGlyphSpinning)
    }

    /// Faster fans turn the glyph faster, and a barely-turning one still turns.
    ///
    /// The scale is deliberately not real: 2500 rpm is 42 turns a second, which at
    /// any frame rate is a blur that reads as broken. This is a needle, not a
    /// simulation — but the ORDER has to survive, or the motion says nothing.
    func testTheGlyphTurnsFasterWhenTheFansDo() throws {
        let rail = SidebarView()
        rail.setFanSpin(rpm: 1200)
        let slow = try XCTUnwrap(rail.fanGlyphTurnSeconds)
        rail.setFanSpin(rpm: 4800)
        let fast = try XCTUnwrap(rail.fanGlyphTurnSeconds)
        XCTAssertLessThan(fast, slow, "a faster fan did not turn the glyph faster")
        // The floor, so a fan barely above zero is still visibly moving rather
        // than taking a minute per turn.
        rail.setFanSpin(rpm: 1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(rail.fanGlyphTurnSeconds), 60)
    }
}
