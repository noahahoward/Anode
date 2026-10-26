import AppKit
import XCTest
@testable import AnodeApp
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
        let deep = root.appendingPathComponent("Anode.app/Contents/MacOS")
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

    /// The licence shows even when the build says nothing about itself.
    ///
    /// This used to assert the opposite — no build info, no options at all —
    /// which was right when the panel's only job was reporting a commit. GPL §5
    /// asks an interactive program to carry its notice where a user can reach
    /// it, and "unless it was built oddly" is not a licence condition. A `swift
    /// run` binary with no Info.plist is exactly the build most likely to be
    /// someone else's copy.
    func testTheLicenceIsShownEvenWithNoBuildInformation() throws {
        let options = AboutPanel.options(info: [:])
        let credits = try XCTUnwrap(options[.credits] as? NSAttributedString)
        XCTAssertTrue(credits.string.contains("GPL-3.0"),
                      "the About box does not say what licence this is under")
        XCTAssertTrue(credits.string.contains("NO WARRANTY"))
        XCTAssertFalse(credits.string.contains("Source commit"),
                       "invented a commit for a build that has none")
    }

    /// And when there IS build information, both appear.
    func testCommitAndLicenceAppearTogether() throws {
        let options = AboutPanel.options(info: ["BSSourceCommit": "d09e75a"])
        let credits = try XCTUnwrap(options[.credits] as? NSAttributedString)
        XCTAssertTrue(credits.string.contains("d09e75a"))
        XCTAssertTrue(credits.string.contains("GPL-3.0"))
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
        XCTAssertTrue(command.contains("AnodeHelper"), command)
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

// An empty top-level menu is a title that opens onto nothing, so the Beta
// Features menu must always have something to show.
/// A stand-in for a beta feature, so the window can be tested without a real one.
private final class FakeFeature: BetaFeature {
    let title: String
    let summary = "A summary."
    var layoutChanged: (() -> Void)?
    var refreshed = 0
    init(_ title: String) { self.title = title }
    func makeView() -> NSView { NSTextField(labelWithString: "controls of \(title)") }
    func refresh() { refreshed += 1 }
}

final class BetaFeaturesWindowTests: XCTestCase {

    private func labels(in window: NSWindow) -> [String] {
        func walk(_ v: NSView) -> [String] {
            ((v as? NSTextField).map { [$0.stringValue] } ?? []) + v.subviews.flatMap(walk)
        }
        return walk(window.contentView!)
    }

    func testItIsAWindowOfItsOwnCalledBetaFeatures() {
        _ = appKitForTests
        let c = BetaFeaturesWindowController(features: [FakeFeature("One")])
        XCTAssertEqual(c.window?.title, "Beta Features")
        XCTAssertFalse(c.window!.isReleasedWhenClosed, "closing it must not free the controller's window")
    }

    func testWithNoFeaturesItSaysSo() {
        _ = appKitForTests
        let c = BetaFeaturesWindowController(features: [])
        XCTAssertTrue(labels(in: c.window!).contains(BetaFeaturesWindowController.emptyText))
    }

    func testEachFeatureGetsASectionInOrder() {
        _ = appKitForTests
        let c = BetaFeaturesWindowController(features: [FakeFeature("Alpha"), FakeFeature("Beta")])
        let all = labels(in: c.window!)
        let a = all.firstIndex(of: "controls of Alpha"), b = all.firstIndex(of: "controls of Beta")
        XCTAssertNotNil(a); XCTAssertNotNil(b)
        XCTAssertLessThan(a!, b!)
        XCTAssertTrue(all.contains("Alpha") && all.contains("Beta"), "each section carries its title")
    }

    func testShowingItRefreshesEveryFeature() {
        _ = appKitForTests
        let f = FakeFeature("One")
        let c = BetaFeaturesWindowController(features: [f])
        let before = f.refreshed
        c.show()
        XCTAssertGreaterThan(f.refreshed, before, "a setting or permission may have changed behind it")
        c.window?.orderOut(nil)
    }

    func testTheSettingsMenuOpensItInsteadOfDroppingDown() {
        // The bar menu must hold a plain item, not a submenu.
        _ = appKitForTests
        let delegate = AppDelegate()
        NSApp.mainMenu = nil
        delegate.buildMenu()
        let settings = NSApp.mainMenu?.items.first { $0.submenu?.title == "Settings" }?.submenu
        let item = settings?.items.first { $0.title == "Beta Features…" }
        XCTAssertNotNil(item, "Settings → Beta Features…")
        XCTAssertNil(item?.submenu, "it opens a window, it does not drop down")
        XCTAssertNotNil(item?.action)
    }
}

// The backdrop's section: what it shows must come from the stored settings and the
// permission, because both change behind it.
final class BackdropFeatureTests: XCTestCase {
    private func make(allowed: Bool = true) -> (BackdropFeature, Settings) {
        _ = appKitForTests
        let defaults = UserDefaults(suiteName: "backdrop-feature-\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults)
        let feature = BackdropFeature(settings: settings, screenRecordingAllowed: { allowed })
        _ = feature.makeView()
        return (feature, settings)
    }

    func testThePopupShowsTheModeInSettings() {
        let (feature, settings) = make()
        for mode in MenuBarBackdropMode.allCases {
            settings.menuBarBackdropMode = mode
            feature.refresh()
            XCTAssertEqual(feature.modePopup.titleOfSelectedItem, mode.title)
        }
    }

    func testChoosingFromThePopupSetsTheMode() {
        let (feature, settings) = make()
        XCTAssertEqual(feature.modePopup.itemTitles, MenuBarBackdropMode.allCases.map(\.title))
        for (i, mode) in MenuBarBackdropMode.allCases.enumerated() {
            feature.modePopup.selectItem(at: i)
            _ = feature.modePopup.target?.perform(feature.modePopup.action, with: feature.modePopup)
            XCTAssertEqual(settings.menuBarBackdropMode, mode)
        }
    }

    func testThePermissionLineAppearsOnlyInTheFollowMode() {
        let (feature, settings) = make(allowed: false)
        settings.menuBarBackdropMode = .solid
        feature.refresh()
        XCTAssertTrue(feature.accessStatus.isHidden)
        XCTAssertTrue(feature.accessButton.isHidden)
        settings.menuBarBackdropMode = .solidFollow
        feature.refresh()
        XCTAssertFalse(feature.accessStatus.isHidden)
        XCTAssertFalse(feature.accessButton.isHidden)
        XCTAssertTrue(feature.accessStatus.stringValue.contains("not allowed"), "a refusal is said, not hidden")
    }

    func testTheSliderIsLiveOnlyInTheBlur() {
        let (feature, settings) = make()
        settings.menuBarBackdropMode = .blur
        feature.refresh()
        XCTAssertTrue(feature.slider.isEnabled)
        settings.menuBarBackdropMode = .solid
        feature.refresh()
        XCTAssertFalse(feature.slider.isEnabled)
    }

    func testDraggingTheSliderWritesTheSetting() {
        let (feature, settings) = make()
        feature.slider.doubleValue = 0.9
        _ = feature.slider.target?.perform(feature.slider.action, with: feature.slider)
        XCTAssertEqual(settings.menuBarBackdropBlur, 0.9, accuracy: 0.001)
    }

    /// Settings can change while the window is open (the menu, `defaults`): it must follow.
    func testItFollowsAChangeMadeElsewhere() {
        let (feature, settings) = make()
        settings.menuBarBackdropMode = .blur
        XCTAssertEqual(feature.modePopup.titleOfSelectedItem, MenuBarBackdropMode.blur.title)
    }
}

final class MenuBarBackdropGeometryTests: XCTestCase {
    private let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)

    func testTheStripCoversTheGapAboveTheVisibleFrame() {
        let visible = NSRect(x: 0, y: 0, width: 1512, height: 982 - 24)
        XCTAssertEqual(MenuBarBackdropGeometry.strip(screenFrame: screen, visibleFrame: visible,
                                                     safeAreaTop: 0),
                       NSRect(x: 0, y: 958, width: 1512, height: 24))
    }

    /// The measured case: a 1169 pt panel with a 38 pt notch whose visible frame
    /// ends 39 pt down. The strip is the notch's height, not the gap's, or it sticks
    /// out 1 pt below the notch.
    func testANotchSetsTheStripHeightNotTheGap() {
        let panel = NSRect(x: 0, y: 0, width: 1800, height: 1169)
        let visible = NSRect(x: 0, y: 0, width: 1800, height: 1130)
        let strip = MenuBarBackdropGeometry.strip(screenFrame: panel, visibleFrame: visible,
                                                  safeAreaTop: 38)
        XCTAssertEqual(strip?.height, 38)
        XCTAssertEqual(strip?.maxY, panel.maxY)
    }

    func testANotchedScreenWithNoBarShowingGetsNoStrip() {
        let panel = NSRect(x: 0, y: 0, width: 1800, height: 1169)
        XCTAssertNil(MenuBarBackdropGeometry.strip(screenFrame: panel, visibleFrame: panel,
                                                   safeAreaTop: 38))
    }

    func testNoMenuBarMeansNoStrip() {
        XCTAssertNil(MenuBarBackdropGeometry.strip(screenFrame: screen, visibleFrame: screen,
                                                   safeAreaTop: 0))
    }

    func testASecondDisplayKeepsItsOwnOrigin() {
        let right = NSRect(x: 1512, y: 100, width: 1920, height: 1080)
        let visible = NSRect(x: 1512, y: 100, width: 1920, height: 1080 - 24)
        XCTAssertEqual(MenuBarBackdropGeometry.strip(screenFrame: right, visibleFrame: visible,
                                                     safeAreaTop: 0),
                       NSRect(x: 1512, y: 1156, width: 1920, height: 24))
    }
}

final class MenuBarBackdropFillTests: XCTestCase {
    func testTheStripIsBlackBehindWhiteTextAndWhiteBehindBlackText() {
        XCTAssertEqual(MenuBarBackdropGeometry.fill(darkBar: true), .black)
        XCTAssertEqual(MenuBarBackdropGeometry.fill(darkBar: false), .white)
    }
}

final class MenuBarBackdropWindowFrameTests: XCTestCase {
    func testTheWindowReachesOneRadiusBelowTheStripAndKeepsItsTop() {
        let strip = NSRect(x: 0, y: 958, width: 1512, height: 24)
        let frame = MenuBarBackdropGeometry.windowFrame(forStrip: strip)
        XCTAssertEqual(frame.maxY, strip.maxY, "the top edge must not move")
        XCTAssertEqual(frame.minY, strip.minY - MenuBarBackdropGeometry.cornerRadius)
        XCTAssertEqual(frame.width, strip.width)
    }
}

final class MenuBarBackdropTintTests: XCTestCase {
    private func grey(_ l: CGFloat) -> NSColor { NSColor(srgbRed: l, green: l, blue: l, alpha: 1) }

    func testWithNoWindowTheTintIsThePlainFillAtGlassAlpha() {
        let t = MenuBarBackdropGeometry.tint(darkBar: true, windowTop: nil, alpha: 0.78).usingColorSpace(.sRGB)!
        XCTAssertEqual(t.redComponent, 0, accuracy: 0.001)
        XCTAssertEqual(t.alphaComponent, 0.78, accuracy: 0.001)
    }

    func testADarkWindowColourIsTakenUnderWhiteText() {
        let t = MenuBarBackdropGeometry.tint(darkBar: true, windowTop: grey(0.16), alpha: 1).usingColorSpace(.sRGB)!
        XCTAssertEqual(t.redComponent, 0.16, accuracy: 0.01)
    }

    /// The case the limit exists for: a bright page under text the system has made white
    /// would be white on white. It is brought DOWN to the limit now, not thrown away for
    /// black — a bar that is black in patches and grey around them is what that looked like.
    func testABrightWindowColourIsBroughtDownToTheLimitUnderWhiteText() {
        let t = MenuBarBackdropGeometry.tint(darkBar: true, windowTop: grey(0.9), alpha: 1).usingColorSpace(.sRGB)!
        XCTAssertEqual(t.redComponent, MenuBarBackdropGeometry.darkBarLimit, accuracy: 0.01)
    }

    func testTheLimitKeepsTheHue() {
        let green = NSColor(srgbRed: 0.2, green: 0.9, blue: 0.3, alpha: 1)
        let t = MenuBarBackdropGeometry.tint(darkBar: true, windowTop: green, alpha: 1).usingColorSpace(.sRGB)!
        XCTAssertGreaterThan(t.greenComponent, t.redComponent, "still green, only darker")
        XCTAssertLessThanOrEqual(0.299 * t.redComponent + 0.587 * t.greenComponent + 0.114 * t.blueComponent,
                                 MenuBarBackdropGeometry.darkBarLimit + 0.005)
    }

    func testADarkWindowColourIsBroughtUpToTheLimitUnderBlackText() {
        let t = MenuBarBackdropGeometry.tint(darkBar: false, windowTop: grey(0.1), alpha: 1).usingColorSpace(.sRGB)!
        XCTAssertEqual(t.redComponent, MenuBarBackdropGeometry.lightBarLimit, accuracy: 0.01)
    }

    /// One bright column in a dark row must not be a hard edge any more.
    func testASharpEdgeInARowIsSoftened() {
        let row = [grey(0.1), grey(0.1), grey(0.1), grey(0.9), grey(0.1), grey(0.1), grey(0.1)]
        let out = MenuBarBackdropGeometry.smoothed(row).map { $0.usingColorSpace(.sRGB)!.redComponent }
        XCTAssertLessThan(out[3], 0.9, "the peak is spread")
        XCTAssertGreaterThan(out[2], 0.1, "its neighbours pick some of it up")
        XCTAssertEqual(out.first!, 0.1, accuracy: 0.02, "the far ends are untouched")
    }

    func testAWindowMeetsTheBarOnlyAtItsEdgeAndNearlyFullWidth() {
        let bar: CGFloat = 38
        XCTAssertTrue(MenuBarBackdropGeometry.meetsBar(
            bounds: CGRect(x: 0, y: 38, width: 1800, height: 900), barBottom: bar, screenWidth: 1800))
        XCTAssertFalse(MenuBarBackdropGeometry.meetsBar(
            bounds: CGRect(x: 100, y: 200, width: 1800, height: 700), barBottom: bar, screenWidth: 1800),
            "a window lower down is not under the bar")
        XCTAssertFalse(MenuBarBackdropGeometry.meetsBar(
            bounds: CGRect(x: 0, y: 38, width: 900, height: 900), barBottom: bar, screenWidth: 1800),
            "half a screen is not maximised")
    }

    func testTheShapeCoversTheBarAndStopsBelowItsWedges() {
        let size = CGSize(width: 400, height: 38 + MenuBarBackdropGeometry.cornerRadius)
        let path = MenuBarBackdropGeometry.shape(in: size)
        let r = MenuBarBackdropGeometry.cornerRadius
        XCTAssertTrue(path.contains(CGPoint(x: 200, y: size.height - 1)), "the bar")
        XCTAssertFalse(path.contains(CGPoint(x: 200, y: r - 1)), "below the bar, mid-screen")
        XCTAssertTrue(path.contains(CGPoint(x: 1, y: r - 1)), "the wedge hugging the left edge")
        XCTAssertFalse(path.contains(CGPoint(x: r - 1, y: 1)), "inside the window's own corner")
    }
}

final class MenuBarBackdropModeTests: XCTestCase {
    func testOffIsClearAndTheSolidModesAreOpaque() {
        XCTAssertEqual(MenuBarBackdropGeometry.tintAlpha(mode: .off), 0)
        XCTAssertEqual(MenuBarBackdropGeometry.tintAlpha(mode: .solid), 1)
        XCTAssertEqual(MenuBarBackdropGeometry.tintAlpha(mode: .solidFollow), 1)
    }

    /// The blur's tint is light and constant: the slider is the blur, not the tint. When
    /// it was the tint, one end of the slider was simply black.
    func testTheBlurModeHasALightConstantTint() {
        let alpha = MenuBarBackdropGeometry.tintAlpha(mode: .blur)
        XCTAssertGreaterThan(alpha, 0)
        XCTAssertLessThan(alpha, 0.5, "light enough that both ends of the slider stay glass")
    }

    func testTheSliderIsTheBlurAmountFromNoneToStrongest() {
        XCTAssertEqual(MenuBarBackdropGeometry.blurRadius(mode: .blur, amount: 0), 0,
                       "see-through is the least blur")
        XCTAssertEqual(MenuBarBackdropGeometry.blurRadius(mode: .blur, amount: 1),
                       MenuBarBackdropGeometry.blurMaxRadius)
        let radii = stride(from: 0.0, through: 1.0, by: 0.25).map {
            MenuBarBackdropGeometry.blurRadius(mode: .blur, amount: $0)
        }
        XCTAssertEqual(radii, radii.sorted(), "more slider, more blur — never less")
        XCTAssertEqual(MenuBarBackdropGeometry.blurRadius(mode: .blur, amount: 9),
                       MenuBarBackdropGeometry.blurRadius(mode: .blur, amount: 1), "out of range is clamped")
    }

    func testOnlyTheBlurModeBlursAnything() {
        for mode in [MenuBarBackdropMode.off, .solid, .solidFollow] {
            XCTAssertEqual(MenuBarBackdropGeometry.blurRadius(mode: mode, amount: 1), 0, "\(mode)")
        }
    }

    /// The blur and the tint share one shape, so the corner wedges are blurred too and the
    /// extra row under the bar is in it: the blur can never reach somewhere the tint does not.
    func testTheBlurReachesAFullPointBelowTheSeamOnTheStraightEdgeOnly() {
        XCTAssertEqual(MenuBarBackdropGeometry.blurExtra, 1.0, "a full point: both pixel rows of the highlight")
        let r = MenuBarBackdropGeometry.cornerRadius
        let size = CGSize(width: 400, height: 39 + r)
        let path = MenuBarBackdropGeometry.shape(in: size, seam: 1, rim: MenuBarBackdropGeometry.rim(for: .blur))
        XCTAssertTrue(path.contains(CGPoint(x: 200, y: r - 0.5)), "the extra row, along the straight edge")
        XCTAssertFalse(path.contains(CGPoint(x: 200, y: r - 1.5)), "and no further")
        XCTAssertTrue(path.contains(CGPoint(x: 1, y: r - 1)), "the corner wedge is there in the blur mode too")
    }

    /// The private blur classes are looked up by name; when they are there the layer carries
    /// a blur filter, and when they are not it is simply absent — never a crash.
    func testTheBackdropBlurIsPresentOrAbsentNeverBroken() {
        _ = appKitForTests
        let frame = CGRect(x: 0, y: 0, width: 100, height: 20)
        guard let layer = BackdropBlur.makeLayer(frame: frame, mask: CGPath(rect: frame, transform: nil)) else { return }
        XCTAssertTrue(BackdropBlur.set(radius: 12, on: layer))
        XCTAssertEqual((layer.value(forKey: "filters") as? [Any])?.count, 1)
        XCTAssertNotNil(layer.mask, "cut to a shape")
    }

    func testTheModeRoundTripsThroughSettings() {
        let defaults = UserDefaults(suiteName: "backdrop-mode-\(UUID().uuidString)")!
        let s = Settings(defaults: defaults)
        XCTAssertEqual(s.menuBarBackdropMode, .solidFollow, "the default")
        for m in MenuBarBackdropMode.allCases {
            s.menuBarBackdropMode = m
            XCTAssertEqual(Settings(defaults: defaults).menuBarBackdropMode, m)
        }
        s.menuBarBackdropBlur = 7
        XCTAssertEqual(s.menuBarBackdropBlur, 1)
    }
}

final class MenuBarBackdropSeamTests: XCTestCase {
    private let panel = NSRect(x: 0, y: 0, width: 1800, height: 1169)

    /// The measured panel: a 38 pt bar and a visible frame ending 39 pt down leave a
    /// 1 pt margin, and that margin is what showed the wallpaper as a hairline.
    func testTheSeamIsTheMarginBetweenTheBarAndTheVisibleFrame() {
        let strip = NSRect(x: 0, y: 1131, width: 1800, height: 38)
        let visible = NSRect(x: 0, y: 0, width: 1800, height: 1130)
        XCTAssertEqual(MenuBarBackdropGeometry.seam(strip: strip, screenFrame: panel,
                                                    visibleFrame: visible), 1)
    }

    func testTheWindowGrowsByTheSeamAndKeepsItsTop() {
        let strip = NSRect(x: 0, y: 1131, width: 1800, height: 38)
        let frame = MenuBarBackdropGeometry.windowFrame(forStrip: strip, seam: 1)
        XCTAssertEqual(frame.maxY, strip.maxY)
        XCTAssertEqual(frame.height, 38 + 1 + MenuBarBackdropGeometry.cornerRadius)
    }

    /// Covered across the whole width, notch or no notch: the bar is one plain strip.
    func testTheSeamIsCoveredAcrossTheWholeWidth() {
        let r = MenuBarBackdropGeometry.cornerRadius
        let size = CGSize(width: 1800, height: 38 + 1 + r)
        let path = MenuBarBackdropGeometry.shape(in: size, seam: 1)
        for x in [5.0, 400.0, 900.0, 1400.0, 1795.0] {
            XCTAssertTrue(path.contains(CGPoint(x: x, y: r + 0.5)), "seam at x=\(x)")
        }
    }
}

final class MenuBarBackdropRimTests: XCTestCase {
    /// The bar reaches one point over the window's own top edge, so the window's
    /// lighter top highlight is covered and the bar meets the titlebar directly.
    func testTheRimIsCoveredOnTheStraightTopEdgeOnly() {
        let r = MenuBarBackdropGeometry.cornerRadius
        let size = CGSize(width: 1800, height: 38 + 1 + r)
        let path = MenuBarBackdropGeometry.shape(in: size, seam: 1, rim: 1)
        XCTAssertTrue(path.contains(CGPoint(x: 900, y: r - 0.5)), "the window's top highlight row")
        XCTAssertFalse(path.contains(CGPoint(x: 900, y: r - 1.5)), "the window itself, below the rim")
        // In the corner zone the window's edge curves away; a rim there is the stripe.
        // Inside the window's own corner (inside the disc the wedge is cut from), nothing is drawn:
        // neither the wedge nor the rim may paint over the window's interior.
        XCTAssertFalse(path.contains(CGPoint(x: r - 2, y: r - 6)), "the window's corner interior stays clear")
        XCTAssertFalse(path.contains(CGPoint(x: 4, y: 4)), "and so does the deeper interior")
    }
}

// ScreenCaptureKit hands back premultiplied pixels, and some of them partly transparent.
// Decoding them as if opaque read every colour darker by the image's own transparency, which
// made the bar visibly darker than the window it was copying.
final class WindowEdgeSamplerDecodeTests: XCTestCase {

    private func image(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat,
                       width: Int = 8, height: Int = 2) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func luminance(_ c: NSColor) -> CGFloat {
        let s = c.usingColorSpace(.sRGB)!
        return (s.redComponent + s.greenComponent + s.blueComponent) / 3
    }

    func testAnOpaqueColourComesBackUnchanged() throws {
        let row = try XCTUnwrap(WindowEdgeSampler.rowColors(of: image(red: 0.6, green: 0.3, blue: 0.2, alpha: 1), columns: 4))
        XCTAssertEqual(row.count, 4)
        XCTAssertEqual(row[0].usingColorSpace(.sRGB)!.redComponent, 0.6, accuracy: 0.02)
    }

    /// The bug: white at half transparency decoded as mid-grey.
    func testAPartlyTransparentColourIsNotDarkened() throws {
        let row = try XCTUnwrap(WindowEdgeSampler.rowColors(of: image(red: 1, green: 1, blue: 1, alpha: 0.5), columns: 4))
        for c in row { XCTAssertEqual(luminance(c), 1, accuracy: 0.03, "white stayed white whatever its alpha") }
    }

    func testAFullyTransparentImageHasNoHonestColour() {
        XCTAssertNil(WindowEdgeSampler.rowColors(of: image(red: 1, green: 1, blue: 1, alpha: 0), columns: 4))
    }
}

// Which stretches of the bar sit over a window, and which sit over wallpaper.
final class MenuBarBackdropMaskTests: XCTestCase {
    private func grey(_ l: CGFloat) -> NSColor { NSColor(srgbRed: l, green: l, blue: l, alpha: 1) }

    func testColumnsOutsideEveryWindowGoBackToThePlainBar() {
        // 10 columns across 0...1000 (no inset); one window covering 0...500.
        let row = (0..<10).map { _ in grey(0.3) }
        let out = MenuBarBackdropGeometry.masked(row, spans: [0...500], inset: 0, width: 1000, base: .black)
        for (i, c) in out.enumerated() {
            let l = c.usingColorSpace(.sRGB)!.redComponent
            XCTAssertEqual(l, i < 5 ? 0.3 : 0, accuracy: 0.001, "column \(i)")
        }
    }

    func testTwoSnappedWindowsBothCountAndTheGapBetweenThemDoesNot() {
        // 10 columns centred at 50, 150 … 950; windows over 0…300 and 700…1000.
        let row = (0..<10).map { _ in grey(0.3) }
        let out = MenuBarBackdropGeometry.masked(row, spans: [0...300, 700...1000], inset: 0, width: 1000, base: .black)
        XCTAssertEqual(out.map { $0.usingColorSpace(.sRGB)!.redComponent > 0.1 },
                       [true, true, true, false, false, false, false, true, true, true])
    }

    func testNoWindowAtAllLeavesTheBarPlainEverywhere() {
        let out = MenuBarBackdropGeometry.masked([grey(0.3), grey(0.3)], spans: [], inset: 0, width: 100, base: .black)
        XCTAssertTrue(out.allSatisfy { $0.usingColorSpace(.sRGB)!.redComponent < 0.001 })
    }
}

final class MenuBarBackdropRimModeTests: XCTestCase {
    /// The blur's tint reaches as far as the blur, or its extra row is brighter than the bar.
    func testTheBlurModeCoversTheWindowTopHighlightAndTheSolidModesDoNot() {
        XCTAssertEqual(MenuBarBackdropGeometry.rim(for: .blur), MenuBarBackdropGeometry.blurExtra)
        for mode in [MenuBarBackdropMode.off, .solid, .solidFollow] {
            XCTAssertEqual(MenuBarBackdropGeometry.rim(for: mode), 0, "\(mode): the bar ends where the window begins")
        }
    }
}

final class MenuBarBackdropRimOverlapTests: XCTestCase {
    /// The rim must overlap the wedge, or a sliver of the window's top highlight shows where
    /// they meet. A point a few units into the corner zone, on the rim's row, is covered.
    func testTheRimRunsIntoTheCornerZonesSoItOverlapsTheWedges() {
        let r = MenuBarBackdropGeometry.cornerRadius
        let size = CGSize(width: 400, height: 39 + r)
        let rim = MenuBarBackdropGeometry.shape(in: size, seam: 1, rim: 1)
        let bare = MenuBarBackdropGeometry.shape(in: size, seam: 1, rim: 0)
        let probe = CGPoint(x: r - 2, y: r - 0.5)      // 2 pt inside the corner zone, on the rim's row
        XCTAssertTrue(rim.contains(probe))
        XCTAssertFalse(bare.contains(probe), "this point is only covered because the rim reaches in")
    }
}

final class MenuBarBackdropShapeUnionTests: XCTestCase {
    /// Where the rim overlaps a wedge the shape must be FILLED, not holed: the two run in opposite
    /// directions, and drawn into one path their windings cancel there. This point is inside both
    /// the left wedge and the rim's reach into the corner zone.
    func testTheRimAndWedgeOverlapIsFilledOnBothSides() {
        let r = MenuBarBackdropGeometry.cornerRadius
        let w: CGFloat = 400
        let path = MenuBarBackdropGeometry.shape(in: CGSize(width: w, height: 39 + r), seam: 1, rim: 1)
        XCTAssertTrue(path.contains(CGPoint(x: 10, y: r - 0.4)), "left overlap")
        XCTAssertTrue(path.contains(CGPoint(x: w - 10, y: r - 0.4)), "right overlap")
    }
}

final class MenuBarBackdropFullScreenTests: XCTestCase {
    private let screen = CGRect(x: 1180, y: 0, width: 1800, height: 1169)

    func testAWindowCoveringTheWholeScreenIsFullScreen() {
        XCTAssertTrue(MenuBarBackdropGeometry.coversWholeScreen(screen, screen: screen))
        XCTAssertTrue(MenuBarBackdropGeometry.coversWholeScreen(screen.insetBy(dx: -1, dy: 1), screen: screen),
                      "a point either way is rounding, not a different window")
    }

    /// A maximised window starts below the menu bar, so the strip must stay for it.
    func testAMaximisedWindowIsNotFullScreen() {
        let maximised = CGRect(x: 1180, y: 39, width: 1800, height: 1130)
        XCTAssertFalse(MenuBarBackdropGeometry.coversWholeScreen(maximised, screen: screen))
    }

    func testAWindowOnAnotherDisplayDoesNotCount() {
        let otherScreen = CGRect(x: 0, y: 0, width: 1180, height: 820)
        XCTAssertFalse(MenuBarBackdropGeometry.coversWholeScreen(otherScreen, screen: screen))
    }
}

final class MenuBarBackdropAppearanceTests: XCTestCase {
    func testTheBarIsDarkUnlessTheAppearanceIsLight() {
        XCTAssertTrue(MenuBarBackdrop.isDark(NSAppearance(named: .darkAqua)!))
        XCTAssertFalse(MenuBarBackdrop.isDark(NSAppearance(named: .aqua)!))
    }

    /// With no widget to read the appearance from, the backdrop must still come up (on the system
    /// appearance) and must not need a status item of its own.
    func testItComesUpWithNoWidgetButtonAtAll() {
        _ = appKitForTests
        let backdrop = MenuBarBackdrop(appearanceButton: { nil })
        XCTAssertNotNil(backdrop)
    }
}

final class WidgetPlacementFullScreenTests: XCTestCase {
    func testNoLookMeansAnythingWhileFullScreenIsUp() {
        XCTAssertFalse(MenuBarWidgetController.lookIsMeaningful(fullScreen: true, secondsSinceSpaceChange: 600))
    }

    func testNoLookMeansAnythingWhileTheItemsAreStillSlidingBack() {
        XCTAssertFalse(MenuBarWidgetController.lookIsMeaningful(fullScreen: false, secondsSinceSpaceChange: 2))
    }

    func testAnOrdinaryLookStillCounts() {
        XCTAssertTrue(MenuBarWidgetController.lookIsMeaningful(
            fullScreen: false, secondsSinceSpaceChange: MenuBarWidgetController.spaceSettleSeconds + 1))
    }
}
