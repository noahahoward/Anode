import XCTest
import AppKit
@testable import AnodeApp

/// The main window must open inside the screen it is on.
///
/// Its 1180 x 660 default was sized on a 16" panel. A MacBook Neo's 13" panel
/// is 1204 x 753 pt at its default scaling, and after the menu bar and the Dock
/// that is less height than the window — so the battery half of it (glance card
/// and graph) opened under the Dock.
final class WindowFitTests: XCTestCase {

    private let minSize = NSSize(width: 760, height: 500)
    /// A Neo's visible frame: 1204 wide, menu bar 24 on top, Dock 64 below.
    private let neo = NSRect(x: 0, y: 64, width: 1204, height: 665)

    func testTheDefaultWindowIsShrunkToTheNeoScreen() throws {
        let tooTall = NSRect(x: 12, y: 40, width: 1180, height: 688)
        let f = try XCTUnwrap(MainWindowController.fitted(tooTall, into: neo, minSize: minSize))
        XCTAssertTrue(neo.contains(f), "\(f) is not inside \(neo)")
        XCTAssertEqual(f.width, 1180, "it fitted across; only the height had to give")
        XCTAssertEqual(f.height, 665)
    }

    /// A frame saved on a big external display, reopened on the laptop alone.
    func testAFrameFromABigDisplayComesBackOnScreen() throws {
        let saved = NSRect(x: 1900, y: 300, width: 1600, height: 1000)
        let f = try XCTUnwrap(MainWindowController.fitted(saved, into: neo, minSize: minSize))
        XCTAssertTrue(neo.contains(f), "\(f) is not inside \(neo)")
    }

    func testAWindowThatFitsIsLeftAlone() throws {
        let fine = NSRect(x: 100, y: 120, width: 900, height: 560)
        XCTAssertEqual(MainWindowController.fitted(fine, into: neo, minSize: minSize), fine)
    }

    /// Never below the minimum: past that the layout itself breaks, and the
    /// title bar staying reachable matters more than the bottom edge.
    func testTheMinimumSizeWinsAndTheTitleBarStaysOnScreen() throws {
        let tiny = NSRect(x: 0, y: 0, width: 700, height: 400)
        let f = try XCTUnwrap(MainWindowController.fitted(NSRect(x: 0, y: 0, width: 1180, height: 688),
                                                         into: tiny, minSize: minSize))
        XCTAssertEqual(f.size, minSize)
        XCTAssertEqual(f.maxY, tiny.maxY, accuracy: 0.5, "the title bar must stay reachable")
    }

    func testNoScreenMeansNoOpinion() {
        XCTAssertNil(MainWindowController.fitted(.zero, into: nil, minSize: minSize))
    }
}
