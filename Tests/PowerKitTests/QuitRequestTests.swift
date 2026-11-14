import XCTest
@testable import AnodeApp

/// A quit asked for from outside gets through a dialog that is on screen. Nothing here puts up a dialog, sends an
/// Apple event or ends the test process: the app is a set of closures the test gives.
final class QuitRequestTests: XCTestCase {

    private var events: [String] = []
    private var sheets = 0
    /// How many more looks find the modal loop still running, after it has been aborted.
    private var modalLooksLeft = 0
    private var modal = false
    private var deferred: [() -> Void] = []

    override func setUp() {
        events = []
        sheets = 0
        modalLooksLeft = 0
        modal = false
        deferred = []
        RunTrace.causeOfADeferredQuit = nil
    }

    override func tearDown() {
        RunTrace.causeOfADeferredQuit = nil
    }

    private var host: QuitRequest.Host {
        QuitRequest.Host(
            sheetEnders: { [unowned self] in
                (0..<sheets).map { i in { [unowned self] in events.append("end sheet \(i)"); sheets -= 1 } }
            },
            modalIsRunning: { [unowned self] in
                guard modal else { return false }
                if events.contains("abort modal") {
                    if modalLooksLeft == 0 { modal = false; return false }
                    modalLooksLeft -= 1
                }
                return true
            },
            abortModal: { [unowned self] in events.append("abort modal") },
            terminate: { [unowned self] in events.append("terminate") },
            later: { [unowned self] in deferred.append($0) })
    }

    /// Runs what was put off, one turn at a time, until nothing is left (or `limit` turns).
    private func turn(_ limit: Int = 1000) {
        var turns = 0
        while !deferred.isEmpty, turns < limit {
            deferred.removeFirst()()
            turns += 1
        }
    }

    /// Nothing in the way: inside the event, as AppKit's own handler does, so who asked is still known to the log.
    func testWithNothingInTheWayItTerminatesAtOnce() {
        let q = QuitRequest()
        q.run(host: host, cause: "the updater")
        XCTAssertEqual(events, ["terminate"])
        XCTAssertTrue(deferred.isEmpty)
        XCTAssertFalse(q.underway)
        XCTAssertNil(RunTrace.causeOfADeferredQuit)
    }

    /// The bug: with the first-run question up as a sheet, the quit was refused and the script that asked found Anode
    /// still running.
    func testASheetIsEndedWithoutAnAnswerAndThenItTerminates() {
        sheets = 1
        let q = QuitRequest()
        q.run(host: host, cause: "the updater")
        XCTAssertEqual(events, ["end sheet 0"], "terminate ran before the sheet had gone")
        XCTAssertTrue(q.underway)
        turn()
        XCTAssertEqual(events, ["end sheet 0", "terminate"])
    }

    func testEverySheetIsEnded() {
        sheets = 2
        QuitRequest().run(host: host)
        turn()
        XCTAssertEqual(events, ["end sheet 0", "end sheet 1", "terminate"])
    }

    /// The helper's notice is app-modal: it is aborted, and `terminate` waits until the modal loop has unwound.
    func testAModalDialogIsAbortedAndTerminateWaitsForTheLoopToUnwind() {
        modal = true
        modalLooksLeft = 3
        let q = QuitRequest()
        q.run(host: host, cause: "the updater")
        XCTAssertEqual(events, ["abort modal"])
        XCTAssertTrue(q.underway)
        turn(3)
        XCTAssertEqual(events, ["abort modal"], "terminate ran inside a modal loop that had not unwound")
        turn()
        XCTAssertEqual(events, ["abort modal", "terminate"])
    }

    func testASheetAndAModalDialogAreBothDismissed() {
        sheets = 1
        modal = true
        QuitRequest().run(host: host)
        turn()
        XCTAssertEqual(events, ["end sheet 0", "abort modal", "terminate"])
    }

    /// A quit that was asked for is not dropped: a loop that never unwinds is given its looks, and then it terminates.
    func testAModalLoopThatNeverUnwindsStillEndsInTerminate() {
        modal = true
        modalLooksLeft = .max
        QuitRequest().run(host: host)
        turn()
        XCTAssertEqual(events, ["abort modal", "terminate"])
        XCTAssertEqual(QuitRequest.unwindLooks, 40)
    }

    /// The Apple event is no longer the current one when a deferred `terminate` runs, so who asked is kept for the log.
    /// The terminate is in place before the dialog is dismissed: dismissing one has been a call that does not return
    /// (an exception the modal loop catches), and a quit that depended on what follows it would dismiss the dialog
    /// and leave the app running.
    func testTheTerminateIsScheduledBeforeAnythingIsDismissed() {
        sheets = 1
        modal = true
        var scheduledBeforeDismissing: Bool?
        var h = host
        let end = h.sheetEnders
        h.sheetEnders = { [unowned self] in
            end().map { ender in { [unowned self] in
                if scheduledBeforeDismissing == nil { scheduledBeforeDismissing = !deferred.isEmpty }
                ender()
            } }
        }
        let abort = h.abortModal
        h.abortModal = { [unowned self] in
            XCTAssertFalse(deferred.isEmpty, "the modal dialog was dismissed with no terminate in place")
            abort()
        }
        QuitRequest().run(host: h)
        XCTAssertEqual(scheduledBeforeDismissing, true)
        turn()
        XCTAssertEqual(events.last, "terminate")
    }

    /// The real host ends a modal dialog with a stop and an event for the loop to find, never with `abortModal`.
    func testTheRealHostStopsAModalDialogWithoutAbortModal() throws {
        let text = try read("Sources/AnodeApp/QuitRequest.swift")
        XCTAssertTrue(text.contains("NSApp.stopModal(withCode: .abort)"))
        XCTAssertTrue(text.contains("NSApp.postEvent(nudge, atStart: true)"))
        XCTAssertFalse(text.contains("NSApp.abortModal()"), "abortModal may not return to its caller")
    }

    func testWhoAskedIsKeptForTheRunLogWhenTheQuitIsDeferred() {
        sheets = 1
        QuitRequest().run(host: host, cause: "Apple event aevt/quit from osascript")
        XCTAssertEqual(RunTrace.causeOfADeferredQuit,
                       "Apple event aevt/quit from osascript; a dialog on screen was dismissed for it")
    }

    // ── The app and the scripts, read from the source ───────────────────────

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testTheAppTakesTheQuitEventOverOnceLaunchHasFinished() throws {
        let main = try read("Sources/AnodeApp/main.swift")
        let launch = try XCTUnwrap(main.range(of: "func applicationDidFinishLaunching(_ note: Notification) {"))
        let install = try XCTUnwrap(main.range(of: "QuitRequest.shared.install()"))
        XCTAssertLessThan(launch.lowerBound, install.lowerBound)
        XCTAssertLessThan(main.distance(from: launch.upperBound, to: install.lowerBound), 400,
                          "installed late: a quit during the rest of launch would still be AppKit's to refuse")
    }

    /// Dismissed for a quit, the first-run question was not answered: it is not written down as seen.
    func testTheFirstRunQuestionIsStillOwedWhenItWasDismissedForAQuit() throws {
        let main = try read("Sources/AnodeApp/main.swift")
        let sheet = try XCTUnwrap(main.range(of: "alert.beginSheetModal(for: self.main.window) { answer in"))
        let seen = try XCTUnwrap(main.range(of: "Settings.shared.autoUpdatePromptSeen = true",
                                            range: sheet.upperBound..<main.endIndex))
        let between = String(main[sheet.upperBound..<seen.lowerBound])
        XCTAssertTrue(between.contains("guard answer == .alertFirstButtonReturn || answer == .alertSecondButtonReturn "
                                       + "else { return }"), between)
    }

    /// A dismissed dialog answers `.abort`. No dialog may take anything but its first button (or OK) for a yes.
    func testNoDialogTakesADismissalForAYes() throws {
        let folder = root.appendingPathComponent("Sources/AnodeApp")
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasSuffix(".swift") {
            let text = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where line.contains("runModal()") {
                XCTAssertFalse(line.contains("runModal() !="), "\(name):\(i + 1) \(line)")
                if line.contains("runModal() ==") {
                    XCTAssertTrue(line.contains("== .alertFirstButtonReturn") || line.contains("== .OK"),
                                  "\(name):\(i + 1) compares with something a dismissal could be: \(line)")
                }
            }
        }
    }

    /// The scripts ask by identifier: the name can reach another registered copy of Anode.app, or start one.
    func testTheScriptsAskAnodeToQuitByItsIdentifier() throws {
        for script in ["uninstall.sh", "build-app.sh"] {
            let text = try read(script)
            XCTAssertFalse(text.contains("tell application \"Anode\" to quit"), script)
            XCTAssertTrue(text.contains("if application id \"dev.anode.app\" is running then tell application id "
                                        + "\"dev.anode.app\" to quit"), script)
        }
    }
}
