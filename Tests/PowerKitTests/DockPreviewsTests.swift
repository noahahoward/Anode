import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

final class DockPreviewsTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)

    // ── Placement (Cocoa coordinates) ──

    func testABottomDockPanelSitsCentredJustAboveTheIcon() {
        let icon = CGRect(x: 400, y: 0, width: 88, height: 88)
        let f = DockPreviewPanel.placement(size: CGSize(width: 420, height: 170), icon: icon, edge: .bottom, screen: screen)
        XCTAssertEqual(f.midX, icon.midX, accuracy: 0.5)
        XCTAssertEqual(f.minY, icon.maxY + DockPreviewPanel.gap)
    }

    func testThePanelStaysOnScreenNearAnEdge() {
        let icon = CGRect(x: 4, y: 0, width: 88, height: 88)
        let f = DockPreviewPanel.placement(size: CGSize(width: 640, height: 170), icon: icon, edge: .bottom, screen: screen)
        XCTAssertEqual(f.minX, DockPreviewPanel.screenMargin)
        let right = DockPreviewPanel.placement(size: CGSize(width: 640, height: 170),
                                               icon: CGRect(x: 1760, y: 0, width: 88, height: 88), edge: .bottom, screen: screen)
        XCTAssertLessThanOrEqual(right.maxX, screen.maxX - DockPreviewPanel.screenMargin)
    }

    func testSideDocksPutThePanelBesideTheIcon() {
        let leftIcon = CGRect(x: 0, y: 500, width: 88, height: 88)
        let l = DockPreviewPanel.placement(size: CGSize(width: 420, height: 170), icon: leftIcon, edge: .left, screen: screen)
        XCTAssertEqual(l.minX, leftIcon.maxX + DockPreviewPanel.gap)
        XCTAssertEqual(l.midY, leftIcon.midY, accuracy: 0.5)
        let rightIcon = CGRect(x: 1712, y: 500, width: 88, height: 88)
        let r = DockPreviewPanel.placement(size: CGSize(width: 420, height: 170), icon: rightIcon, edge: .right, screen: screen)
        XCTAssertEqual(r.maxX, rightIcon.minX - DockPreviewPanel.gap)
    }

    // ── Layout ──

    typealias Panel = DockPreviewPanel

    func testATallWindowGetsANarrowTileAndAWideOneAWideTile() {
        let (frames, _) = Panel.layout(aspects: [0.75, 1.6], limit: CGSize(width: 1784, height: 584))
        XCTAssertEqual(frames[0].width, Panel.previewHeight * 0.75 + 2 * Panel.tileInset, accuracy: 0.01)
        XCTAssertEqual(frames[1].width, Panel.previewHeight * 1.6 + 2 * Panel.tileInset, accuracy: 0.01)
        XCTAssertEqual(frames[0].height, Panel.tileHeight)
    }

    /// The reported waste: one portrait window in a box sized for a landscape one.
    func testThePanelHugsASingleWindow() {
        let (frames, size) = Panel.layout(aspects: [0.6], limit: CGSize(width: 1784, height: 584))
        XCTAssertEqual(size.width, frames[0].width + 2 * Panel.padding, accuracy: 0.01)
        XCTAssertEqual(size.height, Panel.tileHeight + 2 * Panel.padding, accuracy: 0.01)
    }

    func testExtremeShapesAreClamped() {
        let (frames, _) = Panel.layout(aspects: [0.05, 20, .nan], limit: CGSize(width: 1784, height: 584))
        XCTAssertEqual(frames[0].width, Panel.minPreviewWidth + 2 * Panel.tileInset)
        XCTAssertEqual(frames[1].width, Panel.maxPreviewWidth + 2 * Panel.tileInset)
        XCTAssertEqual(frames[2].width, Panel.previewHeight + 2 * Panel.tileInset, "an unknown shape is square")
    }

    func testManyWindowsShrinkThenWrapButNeverOverflowTheWidth() {
        let limit = CGSize(width: 1164, height: 584)
        let (frames, size) = Panel.layout(aspects: Array(repeating: 1.5, count: 20), limit: limit)
        XCTAssertEqual(frames.count, 20)
        XCTAssertLessThanOrEqual(size.width, limit.width + 0.01)
        XCTAssertGreaterThan(Set(frames.map(\.minY)).count, 1, "wrapped onto more than one row")
        XCTAssertEqual(frames[0].height, Panel.tileHeight * 0.5, accuracy: 0.01, "shrunk to the floor first")
        for f in frames { XCTAssertLessThanOrEqual(f.maxX, size.width - Panel.padding + 0.01) }
    }

    // ── Staying open (window-server coordinates: y grows downward) ──

    private let icon = CGRect(x: 400, y: 1080, width: 88, height: 88)
    private let panel = CGRect(x: 250, y: 900, width: 400, height: 170)

    func testTheIconAndThePanelKeepItOpen() {
        XCTAssertTrue(DockPreviews.keepsPanelOpen(pointer: CGPoint(x: 444, y: 1120), icon: icon, panel: panel, slack: 4))
        XCTAssertTrue(DockPreviews.keepsPanelOpen(pointer: CGPoint(x: 300, y: 950), icon: icon, panel: panel, slack: 4))
    }

    func testCrossingTheGapFromIconToPanelKeepsItOpen() {
        // Between the panel's bottom (1070) and the icon's top (1080), straight above the icon.
        let tall = CGRect(x: 400, y: 1100, width: 88, height: 68)
        XCTAssertTrue(DockPreviews.keepsPanelOpen(pointer: CGPoint(x: 444, y: 1085), icon: tall, panel: panel, slack: 0))
    }

    func testMovingAwayClosesIt() {
        XCTAssertFalse(DockPreviews.keepsPanelOpen(pointer: CGPoint(x: 900, y: 600), icon: icon, panel: panel, slack: 4))
        // Along the Dock to a neighbouring icon is not the corridor to this panel.
        XCTAssertFalse(DockPreviews.keepsPanelOpen(pointer: CGPoint(x: 700, y: 1120), icon: icon, panel: panel, slack: 4))
        XCTAssertFalse(DockPreviews.keepsPanelOpen(pointer: CGPoint(x: 700, y: 1120), icon: icon, panel: nil, slack: 4))
    }

    // ── Which windows ──

    private func win(_ id: CGWindowID, pid: pid_t = 7, title: String = "") -> SwitchableWindow {
        SwitchableWindow(id: id, pid: pid, appName: "App", title: title, bounds: CGRect(x: 0, y: 40, width: 800, height: 600))
    }

    func testOnScreenWindowsComeFirstThenMinimizedOnesMarked() {
        let list = WindowCatalog.appWindows(
            onScreen: [win(2), win(9, pid: 8), win(1)],
            accessibility: [AXWindowInfo(id: 1, title: "", frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
                            AXWindowInfo(id: 5, title: "Draft", frame: CGRect(x: 0, y: 0, width: 800, height: 600), minimized: true),
                            AXWindowInfo(id: 0, title: "no id", frame: CGRect(x: 0, y: 0, width: 800, height: 600), minimized: true),
                            AXWindowInfo(id: 6, title: "palette", frame: CGRect(x: 0, y: 0, width: 30, height: 200), minimized: true)],
            pid: 7, appName: "App")
        XCTAssertEqual(list.map(\.id), [2, 1, 5], "this app's on-screen windows, then the minimized one")
        XCTAssertEqual(list.map(\.isOffScreen), [false, false, true])
        XCTAssertEqual(list.last?.title, "Draft")
    }

    /// Finder lists its desktop as a window that is never on screen; it is not minimized and
    /// Finder is not hidden, so it must not become a tile.
    func testAWindowThatIsNeitherOnScreenNorMinimizedIsLeftOut() {
        let desktop = AXWindowInfo(id: 40, title: "", frame: CGRect(x: 0, y: 0, width: 1800, height: 1169))
        XCTAssertEqual(WindowCatalog.appWindows(onScreen: [], accessibility: [desktop], pid: 7, appName: "Finder"), [])
        XCTAssertEqual(WindowCatalog.appWindows(onScreen: [], accessibility: [desktop], pid: 7, appName: "Finder",
                                                appHidden: true).map(\.id), [40], "a hidden app's windows are offered")
    }

    // ── Setting and section ──

    func testTheSettingDefaultsToOffAndRoundTrips() {
        let defaults = UserDefaults(suiteName: "dock-previews-\(UUID().uuidString)")!
        let s = Settings(defaults: defaults)
        XCTAssertFalse(s.dockPreviewsEnabled)
        s.dockPreviewsEnabled = true
        XCTAssertTrue(Settings(defaults: defaults).dockPreviewsEnabled)
    }

    func testTheCheckboxWritesTheSetting() {
        let defaults = UserDefaults(suiteName: "dock-previews-\(UUID().uuidString)")!
        let s = Settings(defaults: defaults)
        let f = DockPreviewFeature(settings: s, accessibilityAllowed: { true })
        _ = f.makeView()
        f.enableCheckbox.state = .on
        _ = f.enableCheckbox.target?.perform(f.enableCheckbox.action)
        XCTAssertTrue(s.dockPreviewsEnabled)
        XCTAssertTrue(f.accessButton.isHidden)
    }

    func testTheBetaWindowListsIt() {
        XCTAssertTrue(BetaFeaturesWindowController().features.contains { $0 is DockPreviewFeature })
    }
}
