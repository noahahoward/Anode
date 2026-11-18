import XCTest
@testable import PowerKit
@testable import AnodeApp

/// Anode's Sound and Battery menus hang from macOS's own icons. A plain click of the left button on the icon is taken by the click
/// gate (it toggles Anode's menu); a right click or Control-click is not, so macOS opens its own context menu there ("Show
/// Percentage", "Remove from Menu Bar"), and Anode's menu used to stay up beside it. And a left click on the icon while that context
/// menu was up opened Anode's menu without macOS ever seeing the click that would have closed the context menu. The two are never
/// up together now.
final class ContextMenuClickAwayTests: XCTestCase {

    // ── A press of the mouse while Anode's menu is up ───────────────────────

    func testAPlainLeftClickOnTheIconIsTheIconsOwnToggleAndDoesNotCloseFromHere() {
        XCTAssertFalse(ClickAway.closes(onIcon: true, onMenu: false, plainLeftPress: true))
    }

    func testARightClickOrAControlClickOnTheIconClosesTheMenuBecauseMacOSOpensItsOwnMenuThere() {
        // Not a plain left press: a right button, a middle button, or the left with Command, Option or Control held (the gate passes
        // all of these on to macOS).
        XCTAssertTrue(ClickAway.closes(onIcon: true, onMenu: false, plainLeftPress: false))
    }

    func testAClickAnywhereElseClosesIt() {
        XCTAssertTrue(ClickAway.closes(onIcon: false, onMenu: false, plainLeftPress: true))
        XCTAssertTrue(ClickAway.closes(onIcon: false, onMenu: false, plainLeftPress: false))
    }

    func testAClickOnTheMenuItselfNeverClosesItFromHere() {
        for plain in [true, false] {
            XCTAssertFalse(ClickAway.closes(onIcon: false, onMenu: true, plainLeftPress: plain))
            XCTAssertFalse(ClickAway.closes(onIcon: true, onMenu: true, plainLeftPress: plain))
        }
    }

    // ── Esc ─────────────────────────────────────────────────────────────────

    func testEscClosesTheMenuWhenItIsPressedAfterTheMenuCameUp() {
        XCTAssertTrue(ClickAway.escapeCloses(keyCode: 53, eventTime: 1000.5, openedAt: 1000))
    }

    func testAnEscPressedBeforeTheMenuOpenedDoesNotCloseIt() {
        // The Esc that closes the context menu is sent just before Anode's menu opens, and arrives at a listener that is already there.
        XCTAssertFalse(ClickAway.escapeCloses(keyCode: 53, eventTime: 999.9, openedAt: 1000))
        XCTAssertFalse(ClickAway.escapeCloses(keyCode: 53, eventTime: 1000, openedAt: 1000))
    }

    func testAnotherKeyNeverClosesIt() {
        XCTAssertFalse(ClickAway.escapeCloses(keyCode: 36, eventTime: 1001, openedAt: 1000))
    }

    // ── macOS's context menu ────────────────────────────────────────────────

    /// What was measured on macOS 27.3 after a right click on the Battery icon: a window of Control Center at the menu level.
    private let controlCenter: Int32 = 482
    private let contextMenu = MenuBarContextMenu.Window(ownerPID: 482, layer: 101, bounds: CGRect(x: 1503, y: -35, width: 344, height: 242))
    private let bar = MenuBarContextMenu.Window(ownerPID: 90, layer: 24, bounds: CGRect(x: 0, y: 0, width: 1800, height: 39))

    func testTheContextMenuIsOpenWhenControlCenterHasAMenuWindowOnTheScreen() {
        XCTAssertTrue(MenuBarContextMenu.isOpen(windows: [bar, contextMenu], owner: controlCenter, panelIsOpen: false))
    }

    func testNothingIsOpenWithoutSuchAWindow() {
        XCTAssertFalse(MenuBarContextMenu.isOpen(windows: [bar], owner: controlCenter, panelIsOpen: false))
        XCTAssertFalse(MenuBarContextMenu.isOpen(windows: [], owner: controlCenter, panelIsOpen: false))
    }

    func testMacOSsOwnPanelIsNotAContextMenu() {
        // It is a window of the same kind; Accessibility lists it for Control Center and does not list the context menu.
        let panel = MenuBarContextMenu.Window(ownerPID: 482, layer: 101, bounds: CGRect(x: 1124, y: 39, width: 522, height: 1102))
        XCTAssertFalse(MenuBarContextMenu.isOpen(windows: [bar, panel], owner: controlCenter, panelIsOpen: true))
    }

    func testAPanelAnodeHasParkedOffTheScreenWhileItReadsIsNotOne() {
        let parked = MenuBarContextMenu.Window(ownerPID: 482, layer: 101, bounds: CGRect(x: -2000, y: 39, width: 522, height: 1102))
        XCTAssertFalse(MenuBarContextMenu.isOpen(windows: [parked], owner: controlCenter, panelIsOpen: false))
    }

    func testAWindowOfAnotherProcessOrLevelIsNotOne() {
        let other = MenuBarContextMenu.Window(ownerPID: 777, layer: 101, bounds: CGRect(x: 1503, y: -35, width: 344, height: 242))
        let lower = MenuBarContextMenu.Window(ownerPID: 482, layer: 3, bounds: CGRect(x: 1503, y: -35, width: 344, height: 242))
        XCTAssertFalse(MenuBarContextMenu.isOpen(windows: [other, lower], owner: controlCenter, panelIsOpen: false))
    }

    // ── It is wired in ──────────────────────────────────────────────────────

    private func source(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/AnodeApp/\(name)"), encoding: .utf8)
    }

    func testBothMenusCloseByTheSameRuleAndIgnoreAnEscFromBeforeTheyOpened() throws {
        for file in ["SoundMenuPanel.swift", "BatteryMenuPanel.swift"] {
            let text = try source(file)
            XCTAssertTrue(text.contains("ClickAway.closes(onIcon:"), "\(file) does not close by the shared rule")
            XCTAssertTrue(text.contains("ClickAway.escapeCloses(keyCode:"), "\(file) does not ignore an Esc from before it opened")
            XCTAssertTrue(text.contains("openedAt = ProcessInfo.processInfo.systemUptime"), "\(file) does not note when it opened")
            XCTAssertFalse(text.contains("if !anchor.contains(top) && !frame.contains(p)"), "\(file) still ignores every press on the icon")
        }
    }

    func testAPlainLeftClickIsJudgedByTheSameModifiersAsTheClickGate() throws {
        // The gate passes a press with Command, Option or Control held on to macOS; the menu must close for exactly those.
        XCTAssertTrue(try source("NativeMenuExtraIcon.swift").contains("[.maskCommand, .maskAlternate, .maskControl]"))
        for file in ["SoundMenuPanel.swift", "BatteryMenuPanel.swift"] {
            XCTAssertTrue(try source(file).contains("intersection([.command, .option, .control])"), "\(file) judges the press by other modifiers")
        }
    }

    func testOpeningAnAnodeMenuClosesAContextMenuOfTheIconFirst() throws {
        let driver = try source("SystemPanelDriver.swift")
        XCTAssertTrue(driver.contains("MenuBarContextMenu.isOpen("))
        XCTAssertTrue(driver.contains("closing the context menu the person opened, with Escape"))
        // Both controllers already call this before they open.
        for file in ["SoundMenuController.swift", "BatteryMenuController.swift"] {
            XCTAssertTrue(try source(file).contains("driver.closePanelOpenedByPerson()"), "\(file) does not close what the person opened")
        }
    }
}
