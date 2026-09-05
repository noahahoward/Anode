import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// A widget that is enabled in config but never appears, permanently.
///
/// macOS persists `NSStatusItem.isVisible` per `autosaveName`, in its OWN store —
/// nothing lands in `dev.anode.app`, so no amount of inspecting this app's config
/// can see it. An item a user once cmd-dragged off the menu bar therefore comes
/// back hidden after every relaunch, rebuild and reinstall, while `WidgetConfig`
/// still reads `enabled: true`, and no control this app offers can recover it.
final class WidgetAutosaveTests: XCTestCase {

    /// The mechanism itself, against the real AppKit that exhibits it.
    ///
    /// This is the whole bug in five lines. It is pinned here rather than argued
    /// in a comment because it is a claim about someone else's framework, and the
    /// day it stops being true is the day the fix above becomes dead weight.
    func testMacOSRemembersAHiddenStatusItemAcrossRecreation() throws {
        let name = "AnodeWidgetAutosaveTest.\(UUID().uuidString)"
        let bar = NSStatusBar.system

        let first = bar.statusItem(withLength: NSStatusItem.variableLength)
        first.autosaveName = name
        try XCTSkipIf(first.button == nil, "no status bar in this environment")
        first.isVisible = false
        bar.removeStatusItem(first)

        let second = bar.statusItem(withLength: NSStatusItem.variableLength)
        second.autosaveName = name
        defer { second.isVisible = true; bar.removeStatusItem(second) }

        XCTAssertFalse(second.isVisible,
                       "AppKit no longer persists isVisible per autosaveName — if this "
                     + "starts passing, the explicit isVisible = true in rebuild() is "
                     + "no longer load-bearing and the comment there is wrong")

        // And the fix: an explicit assignment is enough to recover it.
        second.isVisible = true
        XCTAssertTrue(second.isVisible, "a hidden item could not be made visible again")
    }

    /// The autosave key must not depend on where the widget sits in the list.
    ///
    /// It used to be "AnodeWidget.\(index).\(metricID)". Any add or remove
    /// renumbered every item after it, which discarded the user's cmd-dragged
    /// positions AND handed each item whatever state the previous occupant of its
    /// index had left behind — including a hidden one.
    func testTheAutosaveNameDoesNotDependOnPosition() {
        let name = MenuBarWidgetController.autosaveName(for: MetricID.swapUsed.rawValue)
        XCTAssertFalse(name.contains("0"), "an index leaked back into the autosave name")
        XCTAssertTrue(name.contains(MetricID.swapUsed.rawValue),
                      "the name must still identify which metric it belongs to")
        // Same metric, asked for twice, in a list that changed shape in between.
        XCTAssertEqual(name, MenuBarWidgetController.autosaveName(for: "storage.swap.used"))
        XCTAssertNotEqual(name,
                          MenuBarWidgetController.autosaveName(for: MetricID.cpuUsage.rawValue),
                          "two metrics must not share one remembered position")
    }
}
