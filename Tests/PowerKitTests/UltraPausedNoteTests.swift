import XCTest
import AppKit
@testable import AnodeApp

/// The main window's note that its readings are paused. Ultra Low Power Mode reads only the battery, for the menu bar's "Now",
/// so everything an open window shows is from before the mode: its title bar says so while the mode is on, and only then.
///
/// The window is built and never shown.
final class UltraPausedNoteTests: XCTestCase {

    func testTheTitleBarSaysReadingsArePausedOnlyWhileTheModeIsOn() {
        let controller = MainWindowController()
        XCTAssertEqual(controller.window.subtitle, "", "nothing under the name until the mode is on")

        controller.setReadingsPaused(true)
        XCTAssertEqual(controller.window.subtitle, "Readings paused while Ultra Low Power Mode is on")
        XCTAssertEqual(controller.window.title, "Anode", "the name stays")

        // Said once however often it is asked.
        controller.setReadingsPaused(true)
        XCTAssertEqual(controller.window.subtitle, MainWindowController.readingsPausedNote)

        controller.setReadingsPaused(false)
        XCTAssertEqual(controller.window.subtitle, "", "gone when the mode ends")
    }
}
