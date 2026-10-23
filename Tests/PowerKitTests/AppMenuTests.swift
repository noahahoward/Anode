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
final class BetaMenuTests: XCTestCase {

    func testAnEmptyMenuShowsOneDisabledPlaceholder() {
        _ = appKitForTests
        let menu = NSMenu(title: "Beta Features")
        BetaMenu.fill(menu, with: [])
        XCTAssertEqual(menu.items.map(\.title), [BetaMenu.placeholderTitle])
        menu.update()
        XCTAssertFalse(menu.items[0].isEnabled, "the placeholder must not look clickable")
    }

    func testFeaturesReplaceThePlaceholderAndKeepTheirOrder() {
        _ = appKitForTests
        let menu = NSMenu(title: "Beta Features")
        BetaMenu.fill(menu, with: [NSMenuItem(title: "One", action: nil, keyEquivalent: ""),
                                   NSMenuItem(title: "Two", action: nil, keyEquivalent: "")])
        XCTAssertEqual(menu.items.map(\.title), ["One", "Two"])
    }
}

// The backdrop's controls: what the menu says must come from the stored settings
// and the permission, because both change behind the menu's back.
final class BackdropMenuTests: XCTestCase {
    private func make(allowed: Bool = true) -> (BackdropMenu, Settings) {
        _ = appKitForTests
        let defaults = UserDefaults(suiteName: "backdrop-menu-\(UUID().uuidString)")!
        let settings = Settings(defaults: defaults)
        return (BackdropMenu(settings: settings, screenRecordingAllowed: { allowed }), settings)
    }

    private func checked(_ menu: BackdropMenu) -> [String] {
        menu.refresh()
        return (menu.item.submenu?.items ?? []).filter { $0.state == .on }.map(\.title)
    }

    func testTheModeInSettingsIsTheOneTicked() {
        let (menu, settings) = make()
        for mode in MenuBarBackdropMode.allCases {
            settings.menuBarBackdropMode = mode
            XCTAssertEqual(checked(menu), [mode.title])
        }
    }

    func testEveryModeHasAnItemThatSetsIt() {
        let (menu, settings) = make()
        let items = menu.item.submenu?.items.filter { $0.representedObject is MenuBarBackdropMode } ?? []
        XCTAssertEqual(items.map { $0.representedObject as? MenuBarBackdropMode }, MenuBarBackdropMode.allCases)
        for entry in items {
            _ = entry.target?.perform(entry.action, with: entry)
            XCTAssertEqual(settings.menuBarBackdropMode, entry.representedObject as? MenuBarBackdropMode)
        }
    }

    func testThePermissionLineAppearsOnlyInTheFollowMode() {
        let (menu, settings) = make(allowed: false)
        let status = { menu.item.submenu!.items.first { $0.title.hasPrefix("Screen Recording") }! }
        settings.menuBarBackdropMode = .solid
        menu.refresh()
        XCTAssertTrue(status().isHidden)
        settings.menuBarBackdropMode = .solidFollow
        menu.refresh()
        XCTAssertFalse(status().isHidden)
        XCTAssertTrue(status().title.contains("not allowed"), "a refusal must be said, not hidden")
    }

    func testTheSliderIsLiveOnlyInTheBlur() throws {
        let (menu, settings) = make()
        let slider = try XCTUnwrap(menu.item.submenu?.items.compactMap { ($0.view as? NSStackView)?.views.last as? NSSlider }.first)
        settings.menuBarBackdropMode = .blur
        menu.refresh()
        XCTAssertTrue(slider.isEnabled)
        settings.menuBarBackdropMode = .solid
        menu.refresh()
        XCTAssertFalse(slider.isEnabled)
    }

    func testDraggingTheSliderWritesTheSetting() throws {
        let (menu, settings) = make()
        let slider = try XCTUnwrap(menu.item.submenu?.items.compactMap { ($0.view as? NSStackView)?.views.last as? NSSlider }.first)
        slider.doubleValue = 0.9
        _ = slider.target?.perform(slider.action, with: slider)
        XCTAssertEqual(settings.menuBarBackdropTranslucency, 0.9, accuracy: 0.001)
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

    /// The case the clamp exists for: a bright page under text the system has made
    /// white would be white on white.
    func testABrightWindowColourIsRefusedUnderWhiteText() {
        let t = MenuBarBackdropGeometry.tint(darkBar: true, windowTop: grey(0.9), alpha: 1).usingColorSpace(.sRGB)!
        XCTAssertEqual(t.redComponent, 0, accuracy: 0.001)
    }

    func testADarkWindowColourIsRefusedUnderBlackText() {
        let t = MenuBarBackdropGeometry.tint(darkBar: false, windowTop: grey(0.1), alpha: 1).usingColorSpace(.sRGB)!
        XCTAssertEqual(t.redComponent, 1, accuracy: 0.001)
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
        XCTAssertEqual(MenuBarBackdropGeometry.tintAlpha(mode: .off, translucency: 0.5), 0)
        XCTAssertEqual(MenuBarBackdropGeometry.tintAlpha(mode: .solid, translucency: 0), 1)
        XCTAssertEqual(MenuBarBackdropGeometry.tintAlpha(mode: .solidFollow, translucency: 1), 1,
                       "translucency belongs to blur only")
    }

    func testBlurGrowsMoreSeeThroughAsTheSliderRises() {
        let low = MenuBarBackdropGeometry.tintAlpha(mode: .blur, translucency: 0)
        let high = MenuBarBackdropGeometry.tintAlpha(mode: .blur, translucency: 1)
        XCTAssertGreaterThan(low, high)
        XCTAssertLessThan(low, 1, "even the blur's most solid end must still be glass")
        XCTAssertEqual(MenuBarBackdropGeometry.tintAlpha(mode: .blur, translucency: 9), high,
                       "out of range is clamped")
    }

    func testTheModeRoundTripsThroughSettings() {
        let defaults = UserDefaults(suiteName: "backdrop-mode-\(UUID().uuidString)")!
        let s = Settings(defaults: defaults)
        XCTAssertEqual(s.menuBarBackdropMode, .solidFollow, "the default")
        for m in MenuBarBackdropMode.allCases {
            s.menuBarBackdropMode = m
            XCTAssertEqual(Settings(defaults: defaults).menuBarBackdropMode, m)
        }
        s.menuBarBackdropTranslucency = 7
        XCTAssertEqual(s.menuBarBackdropTranslucency, 1)
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
        XCTAssertFalse(path.contains(CGPoint(x: r - 3, y: r - 0.5)),
                       "no rim across the top of the corner curve")
    }
}
