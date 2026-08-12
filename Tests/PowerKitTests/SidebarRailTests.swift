import AppKit
import XCTest
@testable import AnodeApp
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

    /// THE GLYPH IS ON SCREEN WHETHER IT IS TURNING OR NOT.
    ///
    /// Spinning it means handing it from the image view to a layer, and both
    /// attempts at that hand-off lost it. Hiding the view took the blades with it
    /// — they are its sublayer, and a hidden view hides its whole layer tree — so
    /// the tab went blank the moment the fans started. Reported exactly that way.
    ///
    /// Asserted as "something is drawing it", not as which of the two, because
    /// which one is an implementation detail and the user's complaint was not.
    func testTheFanGlyphIsNeverLostInTheHandOff() {
        let rail = SidebarView()
        XCTAssertTrue(rail.hasVisibleFanGlyph, "no glyph before anything happened")
        rail.setFanSpin(rpm: 2400)
        XCTAssertTrue(rail.hasVisibleFanGlyph, "the glyph vanished when the fans started")
        rail.setFanSpin(rpm: 0)
        XCTAssertTrue(rail.hasVisibleFanGlyph, "the glyph did not come back when they stopped")
        // And through a few changes of speed, which is what a real machine does.
        for rpm in [2400.0, 3600.0, 0.0, 7800.0, 0.0] {
            rail.setFanSpin(rpm: rpm)
            XCTAssertTrue(rail.hasVisibleFanGlyph, "lost at \(rpm) rpm")
        }
    }

    /// The glyph's speed is PROPORTIONAL to the fans', not merely ordered by it.
    ///
    /// Twice the rpm is exactly twice the glyph speed, so the ratio between two
    /// readings is the ratio between the fans that made them. Asserted as a ratio
    /// rather than against fixed durations, because the slowdown constant is a
    /// tuning decision and the proportionality is not.
    ///
    /// The clamps sit outside the real operating range on purpose — 960 to
    /// 12 000 rpm — so every speed this hardware produces is in the proportional
    /// part. These fans run 2317 to 7826.
    func testTheGlyphSpeedSpansTheFansOwnRange() {
        // This machine's fans: they idle just above their minimum and top out far
        // above it, so absolute rpm barely moves in ordinary use.
        let limits = FanPolicy.Limits(minRPM: 2317, maxRPM: 7826)
        let idle = SidebarView.glyphTurnSeconds(rpm: 2318, limits: limits)
        let working = SidebarView.glyphTurnSeconds(rpm: 5000, limits: limits)
        let flatOut = SidebarView.glyphTurnSeconds(rpm: 7826, limits: limits)

        // Monotonic, and the whole visible range is used between the two ends.
        XCTAssertGreaterThan(idle, working)
        XCTAssertGreaterThan(working, flatOut)
        XCTAssertGreaterThan(idle / flatOut, 5,
                             "idle and flat out look nearly the same, which is the "
                             + "complaint this replaced")

        // THE CASE THAT MOTIVATED IT. Proportional to absolute rpm, the two fan
        // speeds this machine actually rests at differ by eight percent — right,
        // and invisible.
        let restA = SidebarView.glyphTurnSeconds(rpm: 2318, limits: limits)
        let restB = SidebarView.glyphTurnSeconds(rpm: 2500, limits: limits)
        XCTAssertGreaterThan(restA / restB, 1.02,
                             "a real change in fan speed produced no visible change")
    }

    /// With no range to normalise against it stays proportional, which is honest
    /// if less legible — a machine whose SMC will not say what its fans can do.
    func testWithoutLimitsItFallsBackToProportional() {
        let a = SidebarView.glyphTurnSeconds(rpm: 1200)
        let b = SidebarView.glyphTurnSeconds(rpm: 2400)
        XCTAssertEqual(a / b, 2, accuracy: 0.001)
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

// ─────────────────────────────────────────────────────────────────────────────

/// The two glyphs that change with the machine.
final class RailGlyphStateTests: XCTestCase {

    override func setUp() { _ = NSApplication.shared }

    /// Every link kind has a glyph this system can actually draw.
    ///
    /// Same rule as the static rail symbols: a name that does not resolve is a
    /// tab that renders as nothing, and the rail is the only way to navigate.
    func testEveryLinkKindHasADrawableGlyph() {
        for kind in [NetworkInventory.Kind.wifi, .ethernet, .thunderbolt,
                     .bridge, .tunnel, .peerToPeer, .other] {
            XCTAssertNotNil(NSImage(systemSymbolName: kind.symbolName,
                                    accessibilityDescription: nil),
                            "\(kind.title) has no drawable glyph (\(kind.symbolName))")
        }
    }

    /// Wi-Fi gets the arc; a cable does not.
    ///
    /// The arc is the most universally read "network" shape and that was the point
    /// of moving off the wire-frame globe — but taken literally it is a lie on a
    /// wired machine, which is what this one is. So the glyph follows the link.
    func testTheGlyphFollowsTheLinkRatherThanAlwaysSayingWiFi() {
        let rail = SidebarView()
        rail.setNetworkKind(.wifi)
        XCTAssertEqual(rail.networkSymbolName, "wifi")
        rail.setNetworkKind(.ethernet)
        XCTAssertNotEqual(rail.networkSymbolName, "wifi",
                          "a wired machine was shown a Wi-Fi glyph")
        // Nothing routing at all falls back to the most recognisable shape.
        rail.setNetworkKind(nil)
        XCTAssertNotNil(rail.networkSymbolName)
    }

    /// The thermometer pulses only when the machine is genuinely hot, and stops.
    ///
    /// This is one of only two things in the app that animate on their own, so the
    /// threshold matters: an alarm that is always on is not an alarm.
    func testTheThermometerAlarmsOnlyWhenCritical() {
        let rail = SidebarView()
        rail.setTemperature(45)
        XCTAssertFalse(rail.isTemperatureAlarming, "an idle machine set the alarm off")
        rail.setTemperature(80)
        XCTAssertFalse(rail.isTemperatureAlarming, "warm is not critical")
        rail.setTemperature(95)
        XCTAssertTrue(rail.isTemperatureAlarming)
        rail.setTemperature(45)
        XCTAssertFalse(rail.isTemperatureAlarming, "the alarm did not clear when it cooled")
    }
}
