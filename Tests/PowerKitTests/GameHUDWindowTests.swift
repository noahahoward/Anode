import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// The strip's window, built but never ordered on screen: the recipe that was verified over a fullscreen game on 2026-11-09
/// is pinned here so a "cleanup" cannot quietly take it apart.
final class GameHUDWindowTests: XCTestCase {

    override func setUp() { _ = NSApplication.shared }

    func testWindowRecipe() {
        let w = GameHUDWindow().makeWindow()
        XCTAssertEqual(w.level, .screenSaver)
        XCTAssertEqual(w.collectionBehavior, [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle])
        XCTAssertTrue(w.ignoresMouseEvents)
        XCTAssertFalse(w.hasShadow)
        XCTAssertFalse(w.canBecomeKey)
        XCTAssertFalse(w.canBecomeMain)
        XCTAssertFalse(w.isOpaque)
        XCTAssertFalse(w.isVisible)
    }

    func testSizeFitsTheText() {
        let hud = GameHUDWindow()
        let short = hud.size(for: "CPU 1")
        let long = hud.size(for: "CPU 62° 41%   GPU 58° 77%   RAM 63%   BAT 84% \u{2212}31 %/hr")
        XCTAssertEqual(short.height, GameHUDPlacement.height)
        XCTAssertEqual(long.height, GameHUDPlacement.height)
        XCTAssertEqual(short.width, 120, "never narrower than 120")
        XCTAssertGreaterThan(long.width, 250)
    }

    func testNothingShowsUntilAskedTo() {
        let hud = GameHUDWindow()
        XCTAssertFalse(hud.isShowing)
        hud.hide()   // hiding what was never shown is harmless
        XCTAssertFalse(hud.isShowing)
    }
}
