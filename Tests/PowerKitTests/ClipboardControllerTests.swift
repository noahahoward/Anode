import XCTest
@testable import PowerKit
@testable import AnodeApp

/// Clipboard History's controller decides when anything runs and what choosing an entry does. Every part that touches the Mac is
/// a closure here, so none of this reads or writes the real clipboard, posts a key or opens a window.
final class ClipboardControllerTests: XCTestCase {

    // ── The fakes ───────────────────────────────────────────────────────────

    private final class FakePresenter: ClipboardPresenting {
        var isOpen = false
        var shows = 0, refreshes = 0, hides = 0
        func show(controller: ClipboardHistoryController) { isOpen = true; shows += 1 }
        func refresh() { refreshes += 1 }
        func hide(completion: @escaping () -> Void) {
            if isOpen { hides += 1 }
            isOpen = false
            completion()
        }
    }

    private final class Rig {
        let settings: Settings
        let directory: URL
        let store: ClipboardStore
        let presenter = FakePresenter()
        var count = 1
        var types: [String] = ["public.utf8-plain-text"]
        var payload: [ClipboardRepresentation]? = []
        var front: (bundleID: String?, name: String?) = ("com.example.Editor", "Editor")
        var trusted = true
        var written: [(reps: [ClipboardRepresentation], plain: Bool)] = []
        var pastes = 0
        var pasteWorks = true
        var restored: [String?] = []
        var timersStarted: [(interval: TimeInterval, tolerance: TimeInterval)] = []
        var timersRunning = 0
        var ticks: [() -> Void] = []
        var registrations = 0, unregistrations = 0
        var fire: (() -> Void)?
        var scheduled: [(delay: TimeInterval, work: () -> Void)] = []
        var lines: [String] = []
        var controller: ClipboardHistoryController!

        init(file: StaticString = #filePath, line: UInt = #line) {
            settings = Settings(defaults: TestDefaults.throwaway("clipboardController"))
            directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("anode-clip-controller-\(UUID().uuidString)", isDirectory: true)
            store = ClipboardStore(directory: directory, limits: ClipboardHistoryController.limits(from: settings))
            controller = ClipboardHistoryController(
                settings: settings, store: store, presenter: presenter,
                changeCount: { [unowned self] in self.count }, types: { [unowned self] in self.types },
                read: { [unowned self] _ in self.payload },
                writePasteboard: { [unowned self] reps, plain in
                    self.written.append((reps, plain)); self.count += 1; return self.count
                },
                sendPaste: { [unowned self] in self.pastes += 1; return self.pasteWorks },
                accessibility: { [unowned self] in self.trusted },
                frontApp: { [unowned self] in self.front },
                restoreFront: { [unowned self] in self.restored.append($0) },
                startTimer: { [unowned self] interval, tolerance, tick in
                    self.timersStarted.append((interval, tolerance)); self.timersRunning += 1; self.ticks.append(tick)
                    return { [unowned self] in self.timersRunning -= 1 }
                },
                registerShortcut: { [unowned self] fire in self.registrations += 1; self.fire = fire },
                unregisterShortcut: { [unowned self] in self.unregistrations += 1; self.fire = nil },
                schedule: { [unowned self] delay, work in self.scheduled.append((delay, work)) },
                accessDescription: { "test" },
                log: { [unowned self] in self.lines.append($0) })
        }

        deinit {
            // Not `controller.shutdown()`: it would call the closures above, which read this object while it is being freed.
            try? FileManager.default.removeItem(at: directory)
        }

        func copy(_ text: String) {
            count += 1
            payload = [ClipboardRepresentation(item: 0, type: "public.utf8-plain-text", data: Data(text.utf8))]
        }

        func runScheduled() { let work = scheduled; scheduled = []; work.forEach { $0.work() } }
    }

    // ── Off, and on ─────────────────────────────────────────────────────────

    /// With the setting off nothing exists: no timer, no key listener, no window.
    func testWithTheSettingOffNothingRuns() {
        let r = Rig()
        XCTAssertFalse(r.controller.isWatching)
        XCTAssertFalse(r.controller.isListeningForShortcut)
        XCTAssertEqual(r.timersStarted.count, 0)
        XCTAssertEqual(r.registrations, 0)
        XCTAssertEqual(r.controller.statusLine(), "Off")
        r.controller.open()
        XCTAssertEqual(r.presenter.shows, 0, "the panel does not open while the feature is off")
    }

    func testTurningItOnListensForTheShortcutAndWatchesWithATolerantTimer() {
        let r = Rig()
        r.settings.clipboardHistoryEnabled = true
        XCTAssertTrue(r.controller.isWatching)
        XCTAssertTrue(r.controller.isListeningForShortcut)
        XCTAssertEqual(r.registrations, 1)
        XCTAssertEqual(r.timersStarted.count, 1)
        XCTAssertEqual(r.timersStarted.first?.interval, ClipboardHistoryController.pollInterval)
        XCTAssertEqual(r.timersStarted.first?.tolerance, ClipboardHistoryController.pollTolerance)
        XCTAssertGreaterThan(ClipboardHistoryController.pollTolerance, 0, "a timer with no tolerance wakes the Mac for nothing")
    }

    func testTurningItOffStopsEverythingAndPutsAnOpenPanelAway() {
        let r = Rig()
        r.settings.clipboardHistoryEnabled = true
        r.presenter.isOpen = true
        r.settings.clipboardHistoryEnabled = false
        XCTAssertEqual(r.timersRunning, 0)
        XCTAssertEqual(r.unregistrations, 1)
        XCTAssertFalse(r.presenter.isOpen)
        XCTAssertFalse(r.controller.isWatching)
    }

    // ── Pausing, sleeping, locking ──────────────────────────────────────────

    /// Paused: nothing is watched, the shortcut still opens the panel. What was copied meanwhile is never recorded.
    func testWhilePausedNothingIsWatchedAndWhatWasCopiedMeanwhileIsNeverRecorded() {
        let r = Rig()
        r.settings.clipboardHistoryEnabled = true
        r.settings.clipboardHistoryPaused = true
        XCTAssertEqual(r.timersRunning, 0)
        XCTAssertTrue(r.controller.isListeningForShortcut)
        r.copy("copied while paused")
        r.settings.clipboardHistoryPaused = false
        XCTAssertEqual(r.timersRunning, 1)
        r.controller.tick()
        XCTAssertTrue(r.store.entries.isEmpty, "the copy made while paused was recorded")
        r.copy("copied after")
        r.controller.tick()
        XCTAssertEqual(r.store.entries.map(\.preview), ["copied after"])
    }

    func testWhileTheScreensSleepOrTheSessionIsLockedNothingIsWatched() {
        let r = Rig()
        r.settings.clipboardHistoryEnabled = true
        r.controller.setScreensAsleep(true)
        XCTAssertEqual(r.timersRunning, 0)
        r.copy("during sleep")
        r.controller.setScreensAsleep(false)
        XCTAssertEqual(r.timersRunning, 1)
        r.controller.setLocked(true)
        XCTAssertEqual(r.timersRunning, 0)
        r.controller.setLocked(false)
        XCTAssertEqual(r.timersRunning, 1)
        r.controller.tick()
        XCTAssertTrue(r.store.entries.isEmpty, "a copy made while nobody watched was recorded")
        XCTAssertTrue(r.controller.statusLine().hasPrefix("Recording"))
        r.controller.setLocked(true)
        XCTAssertTrue(r.controller.statusLine().hasPrefix("Waiting"), r.controller.statusLine())
    }

    func testTheSameStateTwiceDoesNotStartASecondTimer() {
        let r = Rig()
        r.settings.clipboardHistoryEnabled = true
        r.controller.setScreensAsleep(false)
        r.settings.clipboardHistoryKeepImages = false
        XCTAssertEqual(r.timersStarted.count, 1)
        XCTAssertEqual(r.registrations, 1)
    }

    // ── Recording ───────────────────────────────────────────────────────────

    func testACopyIsRecordedAndTheOpenPanelAndTheSectionAreTold() {
        let r = Rig()
        var changes = 0
        r.controller.onChange = { changes += 1 }
        r.settings.clipboardHistoryEnabled = true
        changes = 0
        r.presenter.isOpen = true
        r.copy("something to remember")
        r.controller.tick()
        XCTAssertEqual(r.store.entries.map(\.preview), ["something to remember"])
        XCTAssertEqual(r.store.entries.first?.sourceBundleID, "com.example.Editor")
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(r.presenter.refreshes, 1)
        r.controller.tick()
        XCTAssertEqual(r.store.entries.count, 1, "nothing changed, nothing recorded")
    }

    func testACopyFromAnIgnoredAppIsNotRecordedAndTheLogNeverHoldsTheText() {
        let r = Rig()
        r.settings.clipboardHistoryEnabled = true
        r.settings.clipboardHistoryIgnoredApps = ["com.example.Editor"]
        r.copy("a very private sentence")
        r.controller.tick()
        XCTAssertTrue(r.store.entries.isEmpty)
        XCTAssertTrue(r.lines.contains { $0.contains("ignored app") && $0.contains("com.example.Editor") }, "\(r.lines)")
        XCTAssertFalse(r.lines.contains { $0.contains("private sentence") }, "the log held what was copied")
    }

    func testLimitsFollowTheSettings() {
        let r = Rig()
        r.settings.clipboardHistoryKeepMinutes = 60
        r.settings.clipboardHistoryMaxEntries = 120
        let limits = ClipboardHistoryController.limits(from: r.settings)
        XCTAssertEqual(limits.maxAge, 3600)
        XCTAssertEqual(limits.maxEntries, 120)
        XCTAssertEqual(limits.maxEntryBytes, ClipboardHistoryController.maxEntryBytes)
        XCTAssertEqual(limits.maxTotalBytes, ClipboardHistoryController.maxTotalBytes)
        r.settings.clipboardHistoryKeepMinutes = 0
        XCTAssertNil(ClipboardHistoryController.limits(from: r.settings).maxAge, "0 is for ever")
        r.settings.clipboardHistoryEnabled = true
        r.settings.clipboardHistoryMaxEntries = 40
        XCTAssertEqual(r.store.limits.maxEntries, 40, "a change of setting reaches the store")
    }

    // ── The panel ───────────────────────────────────────────────────────────

    func testTheShortcutOpensAndClosesThePanelAndRemembersTheAppInFront() {
        let r = Rig()
        r.settings.clipboardHistoryEnabled = true
        r.fire?()
        XCTAssertTrue(r.presenter.isOpen)
        XCTAssertEqual(r.presenter.shows, 1)
        r.fire?()
        XCTAssertFalse(r.presenter.isOpen)
        XCTAssertEqual(r.restored.count, 1)
        XCTAssertEqual(r.restored.first ?? nil, "com.example.Editor", "the app that was in front is put back")
    }

    /// Whatever was copied in the last second is in the list when the panel opens.
    func testOpeningLooksAtTheClipboardFirst() {
        let r = Rig()
        r.settings.clipboardHistoryEnabled = true
        r.copy("copied a moment ago")
        r.controller.open()
        XCTAssertEqual(r.store.entries.map(\.preview), ["copied a moment ago"])
    }

    func testResultsAreSearched() {
        let r = Rig()
        r.settings.clipboardHistoryEnabled = true
        r.copy("alpha"); r.controller.tick()
        r.copy("beta"); r.controller.tick()
        XCTAssertEqual(r.controller.results(for: "").map(\.preview), ["beta", "alpha"])
        XCTAssertEqual(r.controller.results(for: "alp").map(\.preview), ["alpha"])
    }

    // ── Choosing ────────────────────────────────────────────────────────────

    private func twoEntries(_ r: Rig) -> (older: UUID, newer: UUID) {
        r.settings.clipboardHistoryEnabled = true
        r.copy("older entry"); r.controller.tick()
        r.copy("newer entry"); r.controller.tick()
        return (r.store.entries[1].id, r.store.entries[0].id)
    }

    /// The whole paste: the entry goes back on the clipboard, that change is not recorded again, the entry moves to the top, the
    /// panel goes, the app that was in front is put back, and only then (after a moment) is ⌘V sent.
    func testChoosingPastesIntoTheAppThatWasInFrontAndRecordsNothingNew() {
        let r = Rig()
        let ids = twoEntries(r)
        r.controller.open()
        r.controller.choose(ids.older, mode: .paste)
        XCTAssertEqual(r.written.count, 1)
        XCTAssertEqual(String(data: r.written[0].reps[0].data, encoding: .utf8), "older entry")
        XCTAssertFalse(r.written[0].plain)
        XCTAssertFalse(r.presenter.isOpen)
        XCTAssertEqual(r.restored.last ?? nil, "com.example.Editor")
        XCTAssertEqual(r.pastes, 0, "⌘V waits for the app in front to be front again")
        XCTAssertEqual(r.scheduled.first?.delay, ClipboardHistoryController.pasteDelay)
        r.runScheduled()
        XCTAssertEqual(r.pastes, 1)
        // The change Anode made to the clipboard is not a copy to record, and the entry is at the top.
        r.controller.tick()
        XCTAssertEqual(r.store.entries.count, 2)
        XCTAssertEqual(r.store.entries.first?.id, ids.older)
    }

    func testPlainTextAsksForPlainText() {
        let r = Rig()
        let ids = twoEntries(r)
        r.controller.open()
        r.controller.choose(ids.newer, mode: .plainText)
        XCTAssertTrue(r.written[0].plain)
        r.runScheduled()
        XCTAssertEqual(r.pastes, 1)
    }

    func testCopyOnlyPutsItOnTheClipboardAndSendsNothing() {
        let r = Rig()
        let ids = twoEntries(r)
        r.controller.open()
        r.controller.choose(ids.older, mode: .copyOnly)
        XCTAssertEqual(r.written.count, 1)
        XCTAssertTrue(r.scheduled.isEmpty, "a copy that is not a paste schedules no ⌘V")
        XCTAssertEqual(r.pastes, 0)
    }

    func testWithoutAccessibilityTheEntryIsOnTheClipboardAndTheLogSaysWhy() {
        let r = Rig()
        let ids = twoEntries(r)
        r.pasteWorks = false
        r.controller.open()
        r.controller.choose(ids.older, mode: .paste)
        r.runScheduled()
        XCTAssertTrue(r.lines.contains { $0.contains("Accessibility") }, "\(r.lines)")
        XCTAssertFalse(r.lines.contains { $0.contains("older entry") })
    }

    /// An entry whose contents are gone from disk cannot be pasted: it is removed, not left to fail again.
    func testAnEntryWhoseContentsAreGoneIsRemoved() throws {
        let r = Rig()
        let ids = twoEntries(r)
        try FileManager.default.removeItem(at: r.directory.appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent(ids.older.uuidString, isDirectory: true))
        r.controller.open()
        r.controller.choose(ids.older, mode: .paste)
        XCTAssertNil(r.store.entry(ids.older))
        XCTAssertTrue(r.written.isEmpty)
        XCTAssertTrue(r.scheduled.isEmpty)
    }

    // ── Deleting, pinning, forgetting ───────────────────────────────────────

    func testDeletePinAndForgetEverythingTellThePanel() {
        let r = Rig()
        let ids = twoEntries(r)
        r.presenter.isOpen = true
        let before = r.presenter.refreshes
        r.controller.togglePin(ids.older)
        XCTAssertEqual(r.store.entry(ids.older)?.pinned, true)
        r.controller.togglePin(ids.older)
        XCTAssertEqual(r.store.entry(ids.older)?.pinned, false)
        r.controller.delete(ids.newer)
        XCTAssertNil(r.store.entry(ids.newer))
        r.controller.forgetEverything()
        XCTAssertTrue(r.store.entries.isEmpty)
        XCTAssertEqual(r.presenter.refreshes, before + 4)
    }

    func testForgettingEverythingTakesThePinnedToo() {
        let r = Rig()
        let ids = twoEntries(r)
        r.controller.togglePin(ids.older)
        r.controller.forgetEverything()
        XCTAssertTrue(r.store.entries.isEmpty)
    }

    // ── Accessibility ───────────────────────────────────────────────────────

    /// The key listener cannot start without Accessibility, and it is granted in System Settings after the switch was turned on:
    /// when it is, the shortcut is asked for again.
    func testWhenAccessibilityIsGrantedLaterTheShortcutIsRegisteredAgain() {
        let r = Rig()
        r.trusted = false
        r.settings.clipboardHistoryEnabled = true
        XCTAssertEqual(r.registrations, 1)
        XCTAssertTrue(r.controller.needsAccessibility)
        XCTAssertTrue(r.controller.statusLine().contains("Accessibility"), r.controller.statusLine())
        r.controller.tick()
        XCTAssertEqual(r.registrations, 1, "still not granted")
        r.trusted = true
        r.controller.tick()
        XCTAssertEqual(r.registrations, 2)
        r.controller.tick()
        XCTAssertEqual(r.registrations, 2, "once")
        XCTAssertFalse(r.controller.needsAccessibility)
    }

    /// Recording needs no Accessibility: only the shortcut and the paste do.
    func testRecordingGoesOnWithoutAccessibility() {
        let r = Rig()
        r.trusted = false
        r.settings.clipboardHistoryEnabled = true
        r.copy("still recorded")
        r.controller.tick()
        XCTAssertEqual(r.store.entries.map(\.preview), ["still recorded"])
    }

    // ── Shutting down ───────────────────────────────────────────────────────

    func testAfterShutdownNothingIsRecordedAndNothingOpens() {
        let r = Rig()
        r.settings.clipboardHistoryEnabled = true
        r.controller.shutdown()
        XCTAssertEqual(r.timersRunning, 0)
        r.copy("too late")
        r.controller.tick()
        r.controller.open()
        XCTAssertTrue(r.store.entries.isEmpty)
        XCTAssertEqual(r.presenter.shows, 0)
        r.settings.clipboardHistoryEnabled = false
        r.settings.clipboardHistoryEnabled = true
        XCTAssertEqual(r.timersStarted.count, 1, "a finished controller does not start again")
    }
}
