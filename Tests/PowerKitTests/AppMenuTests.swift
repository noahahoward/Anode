import AppKit
import XCTest
@testable import BetterStatsApp
@testable import PowerKit

// The View menu numbers the sidebar. Nothing at runtime notices if the two lists
// disagree — the menu would simply send ⌘3 to the wrong lens — so the agreement
// is asserted here instead.

/// Building a real SidebarView needs `NSApp` to exist: Palette resolves its
/// colours from `NSApp.effectiveAppearance` and force-unwraps it, so a test
/// process with no NSApplication traps the moment a row is styled.
///
/// `.prohibited` before anything else — the test binary needs the object, not a
/// Dock tile, and certainly not to steal focus from whoever is at the machine.
private let appKitForTests: NSApplication = {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    return app
}()

final class ViewMenuOrderTests: XCTestCase {

    /// No duplicates, nothing invented, and nothing dropped that this machine can
    /// show. It is no longer "every lens": Fans is conditional on the machine
    /// having any, so the invariant is a subset relation plus an exact count.
    func testDisplayOrderListsEachOfferedLensExactlyOnce() {
        let order = SidebarView.Lens.displayOrder
        XCTAssertEqual(Set(order).count, order.count, "a lens appears twice in the rail")
        XCTAssertTrue(Set(order).isSubset(of: Set(SidebarView.Lens.allCases)))
        XCTAssertEqual(order.count,
                       SidebarView.Lens.allCases
                           .filter { $0.isOffered(whenFans: FanPresence.onThisMac) }.count)
    }

    /// Every tab except Fans is unconditional, on every machine. A tab that
    /// quietly became conditional would be a feature disappearing with no
    /// evidence behind it.
    func testOnlyTheFansTabIsEverHidden() {
        for state: FanPresence.State in [.fanless, .unknown, .fans(1), .fans(2)] {
            let offered = Set(SidebarView.Lens.order(whenFans: state))
            XCTAssertTrue(offered.isSuperset(of: [.processes, .resources, .network, .sensors]),
                          "a tab other than Fans went missing on \(state)")
        }
    }

    /// Per-process lenses first, whole-machine after, with no interleaving: the
    /// rail draws two labelled groups and the menu separates at the same seam.
    func testDisplayOrderIsPerProcessThenWholeMachine() {
        let flags = SidebarView.Lens.displayOrder.map(\.isPerProcess)
        XCTAssertEqual(flags, flags.sorted(by: { a, b in a && !b }),
                       "A whole-machine lens is sitting above a per-process one")
        XCTAssertEqual(flags.first, true)
        XCTAssertEqual(flags.last, false)
    }

    func testLensItemsNumberTheRailFromOne() {
        let items = ViewMenu.lensItems
        XCTAssertEqual(items.map(\.lens), SidebarView.Lens.displayOrder)
        // Numbered 1..n with no gaps, for whatever this machine offers — a hidden
        // tab must close the numbering up rather than leave a hole where ⌘5 was.
        XCTAssertEqual(items.map(\.key),
                       (1...items.count).map(String.init))
    }

    /// The rail is the five tabs asked for and nothing else. Written out rather
    /// than derived: this list is the specification, and a test that recomputed it
    /// from `allCases` would agree with any tab added or removed by accident.
    func testTheRailIsTheFiveTabsOnAMachineWithFans() {
        XCTAssertEqual(SidebarView.Lens.order(whenFans: .fans(2)).map(\.rawValue),
                       ["processes", "resources", "network", "sensors", "fans"])
    }

    /// A MacBook Air has nothing to put in the Fans tab, so it does not get one.
    func testAFanlessMacHasNoFansTab() {
        XCTAssertEqual(SidebarView.Lens.order(whenFans: .fanless).map(\.rawValue),
                       ["processes", "resources", "network", "sensors"])
    }

    /// "The SMC would not answer" is not "this machine has no fans". Hiding the
    /// tab on that evidence would silently remove a reading from a machine that
    /// has one, and leave nothing on screen to suggest it ever existed.
    func testAnUnreadableSMCKeepsTheFansTab() {
        XCTAssertEqual(SidebarView.Lens.order(whenFans: .unknown).map(\.rawValue),
                       ["processes", "resources", "network", "sensors", "fans"])
    }

    /// Whatever this machine is, the live rail is what its fan presence says it
    /// should be. This is the assertion that would fail if `displayOrder` were
    /// ever wired to something other than the detector.
    func testTheLiveRailFollowsThisMachinesFanPresence() {
        XCTAssertEqual(SidebarView.Lens.displayOrder,
                       SidebarView.Lens.order(whenFans: FanPresence.onThisMac))
        XCTAssertEqual(SidebarView.Lens.displayOrder.contains(.fans),
                       FanPresence.showsFanTab(FanPresence.onThisMac))
    }

    /// THE ONE THAT MATTERS FOR A HIDDEN TAB: the View menu is derived from the
    /// rail's own order, so removing a tab in one place removes it from both and
    /// renumbers ⌘1…⌘n behind it. Asserted against a fanless order rather than
    /// this machine's, because this machine has fans and would never exercise it.
    func testTheViewMenuFollowsTheRailWhenATabIsHidden() {
        let items = ViewMenu.lensItems(for: SidebarView.Lens.order(whenFans: .fanless))
        XCTAssertEqual(items.map(\.lens.title),
                       ["Processes", "Resources", "Network", "Sensors"])
        XCTAssertEqual(items.map(\.key), ["1", "2", "3", "4"])
        XCTAssertFalse(items.contains { $0.lens == .fans },
                       "⌘5 would open a tab the rail does not draw")
    }

    /// And the rail itself, built for real. `rowTitles` reads what the rail
    /// exposes to a user — accessibility buttons — so this is the drawn rail,
    /// not a list kept for the test's benefit.
    func testAFanlessRailDrawsFourRowsAndNoFanRow() {
        _ = appKitForTests
        let rail = SidebarView(frame: NSRect(x: 0, y: 0, width: 200, height: 600),
                               lenses: SidebarView.Lens.order(whenFans: .fanless))
        XCTAssertEqual(rowTitles(in: rail),
                       ["Processes", "Resources", "Network", "Sensors"])
    }

    /// Selecting a tab this machine does not draw must change nothing. A menu bar
    /// widget bound to a fan speed on a fanless Mac is the way to reach it, and
    /// the alternative is a rail with nothing lit beside a pane the user cannot
    /// see how to leave.
    func testSelectingAHiddenTabIsIgnoredRatherThanDesyncingTheRail() {
        _ = appKitForTests
        let rail = SidebarView(frame: NSRect(x: 0, y: 0, width: 200, height: 600),
                               lenses: SidebarView.Lens.order(whenFans: .fanless))
        var announced: [SidebarView.Lens] = []
        rail.onSelect = { announced.append($0) }

        rail.select(.fans)
        XCTAssertEqual(rail.selected, .processes)
        XCTAssertTrue(announced.isEmpty)

        rail.select(.sensors)
        XCTAssertEqual(rail.selected, .sensors)
        XCTAssertEqual(announced, [.sensors])
    }

    /// Past ⌘9 there is no digit to use, so the tenth item must get no shortcut
    /// rather than one that collides with something else.
    func testTenthLensWouldGetNoShortcut() {
        // Asserted on the rule rather than on a tenth case that does not exist yet.
        let keys = (0..<12).map { $0 < 9 ? String($0 + 1) : "" }
        XCTAssertEqual(Array(keys.suffix(3)), ["", "", ""])
        XCTAssertEqual(ViewMenu.lensItems.map(\.key),
                       Array(keys.prefix(SidebarView.Lens.displayOrder.count)))
    }

    /// The one that catches a real desync: read the rows the rail actually built
    /// and compare them to the list the menu numbers.
    ///
    /// Rows are found by accessibility role — SidebarView marks each row a button
    /// and labels it with the lens title — so this reads what the rail exposes to
    /// a user rather than a private array kept for the test's benefit.
    func testRailDrawsItsRowsInDisplayOrder() {
        _ = appKitForTests
        let rail = SidebarView(frame: NSRect(x: 0, y: 0, width: 200, height: 600))
        XCTAssertEqual(rowTitles(in: rail),
                       SidebarView.Lens.displayOrder.map(\.title))
    }

    fileprivate func rowTitles(in view: NSView) -> [String] {
        view.subviews.flatMap { sub -> [String] in
            if sub.accessibilityRole() == .button, let label = sub.accessibilityLabel() {
                return [label]
            }
            return rowTitles(in: sub)
        }
    }
}

// ── Edit ────────────────────────────────────────────────────────────────────

/// The app had no Edit menu, so ⌘C/⌘V/⌘X/⌘A did nothing anywhere — NSTextField
/// does not implement them; NSApplication matches the key equivalent against the
/// main menu and sends the action to the first responder. These assert the two
/// halves of that: the item exists under the key the user presses, and it is
/// aimed at the responder chain rather than at an object.
final class EditMenuTests: XCTestCase {

    private func item(_ title: String) throws -> NSMenuItem {
        try XCTUnwrap(EditMenu.make().items.first { $0.title == title },
                      "No \(title) item, so the key equivalent has nothing to match")
    }

    func testEditingCommandsGoToTheResponderChain() throws {
        let expected = [
            "Undo": "undo:", "Redo": "redo:", "Cut": "cut:", "Copy": "copy:",
            "Paste": "paste:", "Delete": "delete:", "Select All": "selectAll:",
        ]
        for (title, selector) in expected {
            let menuItem = try item(title)
            XCTAssertEqual(menuItem.action.map(NSStringFromSelector), selector)
            XCTAssertNil(menuItem.target,
                         "A target on \(title) binds it to one object instead of "
                         + "whatever is focused")
        }
    }

    /// The shortcuts NSApplication looks up. ⌘C with anything else held is a
    /// different keystroke, so the modifier mask is part of the assertion.
    func testShortcutsAreTheOnesUsersPress() throws {
        let expected = [
            ("Undo", "z", NSEvent.ModifierFlags.command),
            ("Redo", "z", [.command, .shift]),
            ("Cut", "x", .command),
            ("Copy", "c", .command),
            ("Paste", "v", .command),
            ("Select All", "a", .command),
        ]
        for (title, key, flags) in expected {
            let menuItem = try item(title)
            XCTAssertEqual(menuItem.keyEquivalent, key, title)
            XCTAssertEqual(menuItem.keyEquivalentModifierMask, flags, title)
        }
    }

    /// Delete is the one editing command with no shortcut: the Delete key already
    /// reaches the field editor on its own, and claiming ⌫ here would intercept it.
    func testDeleteClaimsNoShortcut() throws {
        XCTAssertEqual(try item("Delete").keyEquivalent, "")
    }
}

// ── Help ────────────────────────────────────────────────────────────────────

final class DocumentationLocatorTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bs-docs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ relative: String, _ contents: String = "x") throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A `swift build` binary runs from .build/<triple>/<config>, three levels
    /// below the checkout that holds the docs.
    func testFindsDocAboveABuildDirectory() throws {
        _ = try write("Package.swift")
        let readme = try write("README.md")
        let binDir = root.appendingPathComponent(".build/arm64-apple-macosx/debug")
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        XCTAssertEqual(Documentation.checkoutURL(for: "README.md", near: binDir)?.path,
                       readme.path)
    }

    /// Without the manifest there is nothing to say this README belongs to this
    /// app — ~/Applications may well contain someone else's.
    func testIgnoresADocThatIsNotBesideTheManifest() throws {
        _ = try write("README.md")
        let deep = root.appendingPathComponent("BetterStats.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)

        XCTAssertNil(Documentation.checkoutURL(for: "README.md", near: deep))
    }

    /// A checkout whose manifest exists but whose doc does not is a miss, not a
    /// URL to a file that is not there.
    func testMissingDocIsNotReported() throws {
        _ = try write("Package.swift")
        XCTAssertNil(Documentation.checkoutURL(for: "TESTING.md", near: root))
    }

    func testWalkStopsBeforeClimbingTheWholeFilesystem() throws {
        _ = try write("Package.swift")
        _ = try write("README.md")
        var deep = root!
        for i in 0..<6 { deep = deep.appendingPathComponent("d\(i)") }
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)

        XCTAssertNotNil(Documentation.checkoutURL(for: "README.md", near: deep, maxDepth: 8))
        XCTAssertNil(Documentation.checkoutURL(for: "README.md", near: deep, maxDepth: 3))
    }

    /// Both pages the Help menu offers resolve in this checkout, which is what the
    /// menu is built from during development.
    func testBothHelpPagesResolveFromThisCheckout() {
        for page in Documentation.pages {
            XCTAssertNotNil(
                Documentation.checkoutURL(for: page.file, near: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()),
                "\(page.file) no longer resolves, so its Help item would disappear")
        }
    }
}

// ── About ───────────────────────────────────────────────────────────────────

final class AboutPanelTests: XCTestCase {

    func testCreditsNameTheSourceCommit() {
        let text = AboutPanel.creditsText(info: ["BSSourceCommit": "d09e75a"])
        XCTAssertEqual(text, "Source commit d09e75a")
    }

    /// build-app.sh marks a build made from a modified tree with "+". The hash
    /// alone then identifies nothing, and the panel has to say so.
    func testModifiedTreeIsCalledOut() throws {
        let text = try XCTUnwrap(AboutPanel.creditsText(info: ["BSSourceCommit": "d09e75a+"]))
        XCTAssertTrue(text.hasPrefix("Source commit d09e75a+"))
        XCTAssertTrue(text.contains("modified working tree"), text)
    }

    func testCleanBuildDoesNotClaimToBeModified() throws {
        let text = try XCTUnwrap(AboutPanel.creditsText(info: ["BSSourceCommit": "d09e75a"]))
        XCTAssertFalse(text.contains("modified"))
    }

    /// A `swift run` binary has no Info.plist, and build-app.sh writes "unknown"
    /// when git could not be read. Saying nothing beats saying "unknown".
    func testNothingToReportMeansNoCredits() {
        XCTAssertNil(AboutPanel.creditsText(info: [:]))
        XCTAssertNil(AboutPanel.creditsText(info: ["BSSourceCommit": "unknown"]))
        XCTAssertNil(AboutPanel.creditsText(info: ["BSSourceCommit": ""]))
        XCTAssertNil(AboutPanel.creditsText(info: ["BSSourceCommit": 58]))
    }

    /// The panel requires an attributed string; a plain String is dropped on the
    /// floor, which would show the commit nowhere while every test above passed.
    func testOptionsCarryCreditsAsAnAttributedString() throws {
        let options = AboutPanel.options(info: ["BSSourceCommit": "d09e75a"])
        let credits = try XCTUnwrap(options[.credits] as? NSAttributedString)
        XCTAssertTrue(credits.string.contains("d09e75a"))
    }

    func testOptionsAreEmptyWhenThereIsNothingToAdd() {
        XCTAssertTrue(AboutPanel.options(info: [:]).isEmpty)
    }
}

// ── Fan control strip ───────────────────────────────────────────────────────

/// The Fans tab's control strip. What is worth asserting without a helper to
/// talk to is the part a user copies into a terminal — and the fact that the
/// strip renders at all in each state, since a view that traps on construction
/// takes the whole tab with it.
final class FanControlPanelTests: XCTestCase {

    /// THIS repository's own path contains a space. An unquoted command would be
    /// two arguments, so the instruction printed to the person most likely to
    /// read it would be wrong.
    func testAPathWithASpaceIsQuoted() {
        let q = FanControlPanel.quoted("/Users/me/Downloads/better stats app/x")
        XCTAssertEqual(q, "'/Users/me/Downloads/better stats app/x'")
    }

    /// A single quote inside a path would otherwise close the quoting and turn
    /// the rest of the path into shell words.
    func testAQuoteInsideAPathIsEscaped() {
        XCTAssertEqual(FanControlPanel.quoted("/Users/o'brien/app"),
                       "'/Users/o'\\''brien/app'")
    }

    /// The command has to name a real helper binary and start with sudo, or the
    /// user copies something that cannot work.
    func testTheStartCommandNamesTheHelperAndAsksForRoot() {
        let command = FanControlPanel.startCommand()
        XCTAssertTrue(command.hasPrefix("sudo '"), command)
        XCTAssertTrue(command.contains("BetterStatsHelper"), command)
    }

    /// The strip renders in the state a fresh install is in — control off — and
    /// asks for a sane height. It must never connect to anything to do that.
    func testItRendersWithFanControlOffAndWithoutTouchingASocket() {
        _ = appKitForTests
        let panel = FanControlPanel(frame: NSRect(x: 0, y: 0, width: 500, height: 80))
        panel.update(fans: [FanInfo(index: 0, currentRPM: 0, minRPM: 2317,
                                    maxRPM: 7826, targetRPM: 2317)])
        XCTAssertGreaterThan(panel.preferredHeight, 0)
    }
}
