import AppKit
import XCTest
@testable import AnodeApp

/// "Shown" as AppKit means it against "shown" as a person means it.
///
/// The stranded state cannot be produced in a test — it took the window server
/// rebuilding a Space under a process that had been up for a day and a half —
/// so what is pinned here is the judgement made from the readings taken inside
/// that process, and that every show path uses the one recovery.
final class WindowPresenceTests: XCTestCase {

    /// The exact readings from the stuck process.
    func testOrderedInButOnNoSpaceIsStranded() {
        XCTAssertTrue(WindowPresence.isStranded(isVisible: true, isOnActiveSpace: false,
                                                isMiniaturized: false))
    }

    func testAnOrdinaryOpenWindowIsNotStranded() {
        XCTAssertFalse(WindowPresence.isStranded(isVisible: true, isOnActiveSpace: true,
                                                 isMiniaturized: false))
    }

    /// Closed is closed. Treating it as stranded would order out a window that
    /// is already out, which is harmless, but it would also make the Dock icon
    /// reopen through the wrong branch.
    func testAClosedWindowIsNotStranded() {
        XCTAssertFalse(WindowPresence.isStranded(isVisible: false, isOnActiveSpace: false,
                                                 isMiniaturized: false))
    }

    /// In the Dock on purpose; `deminiaturize` owns that case.
    func testAMiniaturizedWindowIsNotStranded() {
        XCTAssertFalse(WindowPresence.isStranded(isVisible: true, isOnActiveSpace: false,
                                                 isMiniaturized: true))
    }

    /// What `toggle()` asks. With `isVisible` alone this was true for the stuck
    /// window, so a widget click hid something nobody could see.
    func testAStrandedWindowDoesNotCountAsPresented() {
        XCTAssertFalse(WindowPresence.isPresented(isVisible: true, isOnActiveSpace: false))
        XCTAssertTrue(WindowPresence.isPresented(isVisible: true, isOnActiveSpace: true))
        XCTAssertFalse(WindowPresence.isPresented(isVisible: false, isOnActiveSpace: true))
    }

    func testFollowingTheActiveSpaceKeepsWhateverBehaviourWasAlreadySet() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                         styleMask: [.titled], backing: .buffered, defer: true)
        w.collectionBehavior = [.fullScreenPrimary]
        w.followActiveSpace()
        XCTAssertTrue(w.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertTrue(w.collectionBehavior.contains(.fullScreenPrimary))
    }

    func testTheMainWindowFollowsTheActiveSpaceFromConstruction() {
        XCTAssertTrue(MainWindowController().window.collectionBehavior
            .contains(.moveToActiveSpace))
    }

    /// No show path may go back to a bare `makeKeyAndOrderFront`: that is the
    /// call that was a no-op in the stuck process. The About panel is AppKit's
    /// own and is the one exception.
    func testEveryShowPathGoesThroughBringForward() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AnodeApp")
        for file in try FileManager.default.contentsOfDirectory(atPath: dir.path)
        where file.hasSuffix(".swift") && file != "WindowPresence.swift" {
            let text = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            for (n, line) in text.components(separatedBy: "\n").enumerated() {
                let code = line.components(separatedBy: "//")[0]
                XCTAssertFalse(code.contains("makeKeyAndOrderFront("),
                               "\(file):\(n + 1) shows a window without bringForward()")
            }
        }
    }
}
