import XCTest
@testable import PowerKit

/// The pasteboard watcher, with a pasteboard made of closures: a counter the test moves, the types on it, what a read gives,
/// and the app in front. Asking for the counter reads nothing of the copy, so the tests hold the watcher to it: while the
/// counter has not moved no type is asked for and nothing is read, and a copy that must not be recorded is judged from its type
/// strings and its app before any of its contents are read.
final class ClipboardWatcherTests: XCTestCase {

    /// The Mac's pasteboard and front app as the watcher sees them, with a count of every question put to it.
    private final class FakePasteboard {
        var count = 0
        var types: [String] = []
        var payload: [ClipboardRepresentation]? = []
        var frontBundleID: String?
        var frontName: String?
        var policy = ClipboardStore.Policy()
        private(set) var typesCalls = 0
        private(set) var readCalls = 0
        private(set) var readLimits: [Int] = []
        private(set) var log: [String] = []

        func readCount() -> Int { count }

        func readTypes() -> [String] {
            typesCalls += 1
            return types
        }

        func read(_ maxBytes: Int) -> [ClipboardRepresentation]? {
            readCalls += 1
            readLimits.append(maxBytes)
            return payload
        }

        func writeLog(_ line: String) { log.append(line) }

        /// Somebody copies: the counter moves, and these are the forms, from this app.
        func copy(_ reps: [ClipboardRepresentation], from app: String? = nil, named name: String? = nil) {
            count += 1
            payload = reps
            var seen = Set<String>()
            types = reps.map(\.type).filter { seen.insert($0).inserted }
            frontBundleID = app
            frontName = name
        }

        func copyText(_ text: String, extraTypes: [String] = [], from app: String? = nil, named name: String? = nil) {
            var reps = [ClipboardRepresentation(item: 0, type: "public.utf8-plain-text", data: Data(text.utf8))]
            for type in extraTypes { reps.append(ClipboardRepresentation(item: 0, type: type, data: Data("1".utf8))) }
            copy(reps, from: app, named: name)
        }
    }

    private static let secret = "hunter2-correct-horse-battery-staple"

    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var root: URL!
    private var pasteboard: FakePasteboard!
    private var store: ClipboardStore!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("com.anode.tests.clipboard-watcher.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        pasteboard = FakePasteboard()
        store = ClipboardStore(directory: root.appendingPathComponent(ClipboardStore.folderName, isDirectory: true),
                               limits: ClipboardStore.Limits(maxEntries: 100, maxEntryBytes: 1_000_000, maxTotalBytes: 10_000_000, maxAge: nil))
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// A watcher on the fake pasteboard and the real store. Made after the test has set the pasteboard up: it takes the
    /// counter as it is then as already seen.
    private func makeWatcher() -> ClipboardWatcher {
        let p = pasteboard!
        return ClipboardWatcher(
            changeCount: { p.readCount() },
            types: { p.readTypes() },
            read: { p.read($0) },
            frontApp: { (bundleID: p.frontBundleID, name: p.frontName) },
            store: store,
            policy: { p.policy },
            log: { p.writeLog($0) })
    }

    private func recordedID(_ result: ClipboardWatcher.PollResult) -> UUID? {
        if case .recorded(.added(let id)) = result { return id }
        return nil
    }

    // ── Asking, and not reading ─────────────────────────────────────────────

    /// While the counter has not moved nothing is asked of the pasteboard but the counter: no types, no contents.
    func testWhileTheCounterHasNotMovedNothingIsReadAndNothingIsAsked() {
        pasteboard.copyText("copied before the watcher started")
        let watcher = makeWatcher()
        for _ in 0..<5 { XCTAssertEqual(watcher.poll(now: start), .unchanged) }
        XCTAssertEqual(pasteboard.typesCalls, 0)
        XCTAssertEqual(pasteboard.readCalls, 0)
        XCTAssertTrue(store.entries.isEmpty, "what was on the pasteboard before is not a copy to record")
        XCTAssertTrue(pasteboard.log.isEmpty)
    }

    /// A change is read once; polling again before the next change reads nothing more.
    func testACopyIsReadOnceAndThenTheCounterIsUnchangedAgain() {
        let watcher = makeWatcher()
        pasteboard.copyText("a new copy")
        XCTAssertNotNil(recordedID(watcher.poll(now: start)))
        XCTAssertEqual(pasteboard.readCalls, 1)
        XCTAssertEqual(pasteboard.typesCalls, 1)
        XCTAssertEqual(watcher.poll(now: start), .unchanged)
        XCTAssertEqual(watcher.poll(now: start), .unchanged)
        XCTAssertEqual(pasteboard.readCalls, 1)
        XCTAssertEqual(pasteboard.typesCalls, 1)
    }

    /// The read is told how many bytes it may return, which is what the store keeps of one entry: a copy over that is never
    /// pulled into memory.
    func testTheReadIsToldTheSizeOneEntryMayBe() {
        store.limits.maxEntryBytes = 12_345
        let watcher = makeWatcher()
        pasteboard.copyText("small")
        watcher.poll(now: start)
        XCTAssertEqual(pasteboard.readLimits, [12_345])
    }

    // ── Recording a copy ────────────────────────────────────────────────────

    /// A change is recorded with the app in front, which is taken to be the one that copied, and with the time of the poll.
    func testAChangeIsRecordedWithTheFrontAppsIdAndName() throws {
        let watcher = makeWatcher()
        pasteboard.copyText("from the editor", from: "com.example.Editor", named: "Editor")
        let id = try XCTUnwrap(recordedID(watcher.poll(now: start.addingTimeInterval(7))))
        let entry = try XCTUnwrap(store.entry(id))
        XCTAssertEqual(entry.sourceBundleID, "com.example.Editor")
        XCTAssertEqual(entry.sourceName, "Editor")
        XCTAssertEqual(entry.text, "from the editor")
        XCTAssertEqual(entry.date, start.addingTimeInterval(7))
        XCTAssertEqual(store.entries.count, 1)
    }

    /// The same words copied again is the same entry moved up, and the watcher says so.
    func testTheSameCopyAgainIsReportedAsMoved() throws {
        let watcher = makeWatcher()
        pasteboard.copyText("again and again")
        let id = try XCTUnwrap(recordedID(watcher.poll(now: start)))
        pasteboard.copyText("again and again")
        XCTAssertEqual(watcher.poll(now: start.addingTimeInterval(5)), .recorded(.moved(id)))
        XCTAssertEqual(store.entries.count, 1)
    }

    /// The policy is read for each copy, so a change to the list or to the picture switch applies to the next one.
    func testThePolicyIsReadAtEveryCopy() {
        let watcher = makeWatcher()
        pasteboard.copyText("before the list", from: "com.example.Vault")
        XCTAssertNotNil(recordedID(watcher.poll(now: start)))

        pasteboard.policy = ClipboardStore.Policy(ignoredApps: ["com.example.Vault"], keepImages: true)
        pasteboard.copyText("after the list", from: "com.example.Vault")
        XCTAssertEqual(watcher.poll(now: start.addingTimeInterval(1)), .skipped("ignored app"))
        XCTAssertEqual(store.entries.map(\.text), ["before the list"])
    }

    /// What the store refuses for its own reasons is reported as recorded-and-skipped, with the store's word.
    func testWhatTheStoreRefusesComesBackWithItsReason() {
        let watcher = makeWatcher()
        pasteboard.policy = ClipboardStore.Policy(ignoredApps: [], keepImages: false)
        pasteboard.copy([ClipboardRepresentation(item: 0, type: "public.png", data: Data([0, 1, 2, 3]))], from: "com.example.Viewer")
        XCTAssertEqual(watcher.poll(now: start), .recorded(.skipped("images are off")))

        pasteboard.copy([ClipboardRepresentation(item: 0, type: "com.example.private-format", data: Data([1]))], from: "com.example.Viewer")
        XCTAssertEqual(watcher.poll(now: start), .recorded(.skipped("nothing to keep")))
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(pasteboard.log.count, 2, "each is a line in the log")
        XCTAssertTrue(pasteboard.log[0].contains("images are off"))
        XCTAssertTrue(pasteboard.log[1].contains("nothing to keep"))
    }

    // ── Anode's own writes ──────────────────────────────────────────────────

    /// Putting an entry back on the pasteboard to paste it is Anode's own change: it moves the counter and is not a copy.
    func testAnOwnWriteIsNotRecordedAndNothingIsRead() {
        let watcher = makeWatcher()
        pasteboard.count += 1
        pasteboard.types = ["public.utf8-plain-text"]
        pasteboard.payload = [ClipboardRepresentation(item: 0, type: "public.utf8-plain-text", data: Data("pasted from history".utf8))]
        watcher.noteOwnWrite(changeCount: pasteboard.count)

        XCTAssertEqual(watcher.poll(now: start), .ownWrite)
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(pasteboard.readCalls, 0)
        XCTAssertEqual(pasteboard.typesCalls, 0)
        XCTAssertEqual(watcher.poll(now: start), .unchanged, "and it is seen only once")
    }

    /// After an own write, the next copy by anyone else is an ordinary copy.
    func testAfterAnOwnWriteALaterForeignChangeIsRecorded() {
        let watcher = makeWatcher()
        pasteboard.count += 1
        watcher.noteOwnWrite(changeCount: pasteboard.count)
        XCTAssertEqual(watcher.poll(now: start), .ownWrite)

        pasteboard.copyText("a real copy afterwards", from: "com.example.Editor")
        XCTAssertNotNil(recordedID(watcher.poll(now: start.addingTimeInterval(1))))
        XCTAssertEqual(store.entries.map(\.text), ["a real copy afterwards"])
    }

    /// If somebody copies between Anode's write and the next poll the counter has moved past the one Anode noted, so that copy
    /// is not mistaken for the write.
    func testACopyThatLandsBeforeTheNextPollAfterAnOwnWriteIsStillRecorded() {
        let watcher = makeWatcher()
        pasteboard.count += 1
        watcher.noteOwnWrite(changeCount: pasteboard.count)
        pasteboard.copyText("copied right after", from: "com.example.Editor")
        XCTAssertNotNil(recordedID(watcher.poll(now: start)))
        XCTAssertEqual(store.entries.map(\.text), ["copied right after"])
    }

    // ── Starting again ──────────────────────────────────────────────────────

    /// After a pause or a sleep the watcher takes the pasteboard as it is: what was copied while nobody was watching is
    /// never recorded, and the next copy is.
    func testWhatWasCopiedBeforeAResyncIsNeverRecorded() {
        let watcher = makeWatcher()
        pasteboard.copyText("copied while paused", from: "com.example.Editor")
        watcher.resync()
        XCTAssertEqual(watcher.poll(now: start), .unchanged)
        XCTAssertEqual(pasteboard.readCalls, 0)
        XCTAssertTrue(store.entries.isEmpty)

        pasteboard.copyText("copied after", from: "com.example.Editor")
        XCTAssertNotNil(recordedID(watcher.poll(now: start.addingTimeInterval(1))))
        XCTAssertEqual(store.entries.map(\.text), ["copied after"])
    }

    /// An own-write mark from before a pause is forgotten with the rest, so it cannot swallow a real copy that happens to
    /// land on the same counter afterwards.
    func testAResyncForgetsAnOwnWriteThatWasNoted() {
        let watcher = makeWatcher()
        watcher.noteOwnWrite(changeCount: pasteboard.count + 1)
        watcher.resync()
        pasteboard.copyText("a real copy", from: "com.example.Editor")
        XCTAssertNotNil(recordedID(watcher.poll(now: start)))
    }

    // ── What is never read ──────────────────────────────────────────────────

    /// A copy marked concealed (a password, from an app that remembered to say so) is judged from its type strings alone:
    /// the contents are never asked for.
    func testAConcealedCopyIsSkippedAndItsContentsAreNeverRead() {
        let watcher = makeWatcher()
        pasteboard.copyText(Self.secret, extraTypes: ["org.nspasteboard.ConcealedType"], from: "com.example.Editor")
        XCTAssertEqual(watcher.poll(now: start), .skipped("concealed"))
        XCTAssertEqual(pasteboard.readCalls, 0, "read is never called for a copy that is refused")
        XCTAssertTrue(store.entries.isEmpty)
    }

    /// Every marker the rules know is kept from the contents the same way.
    func testNoMarkedCopyHasItsContentsRead() {
        let watcher = makeWatcher()
        for (type, word) in ClipboardPrivacy.markers {
            pasteboard.copyText(Self.secret, extraTypes: [type], from: "com.example.Editor")
            XCTAssertEqual(watcher.poll(now: start), .skipped(word), type)
        }
        XCTAssertEqual(pasteboard.readCalls, 0)
        XCTAssertTrue(store.entries.isEmpty)
    }

    /// A password manager is refused for who it is, marker or none.
    func testACopyFromAPasswordManagerIsSkippedWithoutReadingIt() {
        let watcher = makeWatcher()
        pasteboard.copyText(Self.secret, from: "com.bitwarden.desktop", named: "Bitwarden")
        XCTAssertEqual(watcher.poll(now: start), .skipped("password manager"))
        pasteboard.copyText(Self.secret, from: "com.example.MyBitwardenFork")
        XCTAssertEqual(watcher.poll(now: start), .skipped("password manager"))
        XCTAssertEqual(pasteboard.readCalls, 0)
        XCTAssertTrue(store.entries.isEmpty)
    }

    /// An app on the person's list is refused the same way, and only while it is on the list.
    func testACopyFromAnIgnoredAppIsSkippedWithoutReadingIt() {
        let watcher = makeWatcher()
        pasteboard.policy = ClipboardStore.Policy(ignoredApps: ["com.example.Vault"], keepImages: true)
        pasteboard.copyText(Self.secret, from: "com.example.Vault", named: "Vault")
        XCTAssertEqual(watcher.poll(now: start), .skipped("ignored app"))
        XCTAssertEqual(pasteboard.readCalls, 0)
        XCTAssertTrue(store.entries.isEmpty)

        pasteboard.copyText("from somewhere else", from: "com.example.Editor")
        XCTAssertNotNil(recordedID(watcher.poll(now: start.addingTimeInterval(1))))
        XCTAssertEqual(pasteboard.readCalls, 1)
    }

    /// A copy that cannot be read, or is over the size, is skipped and says so in a word.
    func testAReadThatGivesNothingIsSkipped() {
        let watcher = makeWatcher()
        pasteboard.copyText("unreadable", from: "com.example.Editor")
        pasteboard.payload = nil
        XCTAssertEqual(watcher.poll(now: start), .skipped("too large or unreadable"))
        XCTAssertEqual(pasteboard.readCalls, 1)
        XCTAssertTrue(store.entries.isEmpty)
    }

    // ── The log never has what was copied ───────────────────────────────────

    /// The log says what kind of thing was not recorded and who made it: the reason and the app, never a word of the copy.
    func testTheLogHasTheReasonAndTheAppAndNeverTheCopiedText() {
        let watcher = makeWatcher()
        store.limits.maxEntryBytes = 50

        // Refused before it is read: a marker, a password manager, an app on the list.
        pasteboard.policy = ClipboardStore.Policy(ignoredApps: ["com.example.Vault"], keepImages: true)
        pasteboard.copyText(Self.secret, extraTypes: ["org.nspasteboard.ConcealedType"], from: "com.example.Mail")
        watcher.poll(now: start)
        pasteboard.copyText(Self.secret, from: "com.1password.1password")
        watcher.poll(now: start)
        pasteboard.copyText(Self.secret, from: "com.example.Vault")
        watcher.poll(now: start)
        // Read, and then not kept: too big for one entry. The text went through the store; it must not reach the log.
        pasteboard.copyText(Self.secret + String(repeating: "x", count: 200), from: "com.example.Notes")
        XCTAssertEqual(watcher.poll(now: start), .recorded(.skipped("too large")))
        // Not readable at all.
        pasteboard.copyText(Self.secret, from: "com.example.Editor")
        pasteboard.payload = nil
        watcher.poll(now: start)
        // And from an app the Mac could not name.
        pasteboard.copyText(Self.secret, extraTypes: ["org.nspasteboard.TransientType"])
        watcher.poll(now: start)

        let expected: [(reason: String, app: String)] = [
            ("concealed", "com.example.Mail"), ("password manager", "com.1password.1password"), ("ignored app", "com.example.Vault"),
            ("too large", "com.example.Notes"), ("unreadable", "com.example.Editor"), ("transient", "an unknown app"),
        ]
        XCTAssertEqual(pasteboard.log.count, expected.count, "one line for each copy that was not recorded: \(pasteboard.log)")
        for (line, want) in zip(pasteboard.log, expected) {
            XCTAssertTrue(line.contains(want.reason), "\(line) says why")
            XCTAssertTrue(line.contains(want.app), "\(line) says who")
        }
        for line in pasteboard.log {
            XCTAssertFalse(line.contains(Self.secret), "a log line holds what was copied: \(line)")
            XCTAssertFalse(line.contains("hunter2"), "a log line holds part of what was copied: \(line)")
        }
    }

    /// A copy that is kept leaves no line in the log at all, so the log cannot be read to learn what was copied.
    func testACopyThatIsKeptWritesNothingToTheLog() {
        let watcher = makeWatcher()
        pasteboard.copyText(Self.secret, from: "com.example.Editor")
        XCTAssertNotNil(recordedID(watcher.poll(now: start)))
        XCTAssertTrue(pasteboard.log.isEmpty)
    }
}
