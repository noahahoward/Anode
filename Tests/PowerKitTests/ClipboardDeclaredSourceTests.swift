import XCTest
@testable import PowerKit

/// A copy can say which app it came from (`org.nspasteboard.source`). That is only what the copying app says of itself, so it can name
/// any app: the rules about apps judge it AND the app that was in front, and it only labels the entry.
final class ClipboardDeclaredSourceTests: XCTestCase {

    private var directory: URL!
    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("anode-clip-declared-\(UUID().uuidString)", isDirectory: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func store() -> ClipboardStore {
        ClipboardStore(directory: directory, limits: .init(maxEntries: 50, maxEntryBytes: 1_000_000, maxTotalBytes: 10_000_000, maxAge: nil))
    }
    private func text(_ s: String) -> [ClipboardRepresentation] {
        [ClipboardRepresentation(item: 0, type: "public.utf8-plain-text", data: Data(s.utf8))]
    }

    func testAnIgnoredAppCannotGetPastTheListByNamingAnotherAsItsSource() {
        let s = store()
        let snapshot = ClipboardSnapshot(representations: text("secret"), sourceBundleID: "com.example.Ignored",
                                         declaredSourceBundleID: "com.apple.Safari", sourceName: "Safari")
        XCTAssertEqual(s.add(snapshot, policy: .init(ignoredApps: ["com.example.Ignored"])), .skipped("ignored app"))
        XCTAssertTrue(s.entries.isEmpty)
    }

    func testACopyThatNamesAnIgnoredAppAsItsSourceIsRefusedWhoeverWasInFront() {
        let s = store()
        let snapshot = ClipboardSnapshot(representations: text("secret"), sourceBundleID: "com.apple.Safari",
                                         declaredSourceBundleID: "com.example.Ignored")
        XCTAssertEqual(s.add(snapshot, policy: .init(ignoredApps: ["com.example.Ignored"])), .skipped("ignored app"))
    }

    func testAPasswordManagerThatNamesItselfIsRefusedAndOneThatIsInFrontIsRefusedWhateverItNames() {
        let s = store()
        XCTAssertEqual(s.add(ClipboardSnapshot(representations: text("x"), sourceBundleID: "com.apple.Safari",
                                               declaredSourceBundleID: "com.1password.1password")), .skipped("password manager"))
        XCTAssertEqual(s.add(ClipboardSnapshot(representations: text("y"), sourceBundleID: "com.bitwarden.desktop",
                                               declaredSourceBundleID: "com.apple.Safari")), .skipped("password manager"))
        XCTAssertTrue(s.entries.isEmpty)
    }

    /// With nothing ignored the declared app is what the entry is shown as coming from, and the app in front is what was judged.
    func testTheDeclaredAppLabelsTheEntry() {
        let s = store()
        let snapshot = ClipboardSnapshot(representations: text("hello"), sourceBundleID: "com.example.Front",
                                         declaredSourceBundleID: "com.example.Maker", sourceName: "Maker")
        guard case .added(let id) = s.add(snapshot) else { return XCTFail("not recorded") }
        XCTAssertEqual(s.entry(id)?.sourceBundleID, "com.example.Maker")
        XCTAssertEqual(s.entry(id)?.sourceName, "Maker")
        XCTAssertEqual(snapshot.displayBundleID, "com.example.Maker")
        XCTAssertEqual(ClipboardSnapshot(representations: [], sourceBundleID: "com.example.Front").displayBundleID, "com.example.Front")
    }

    func testTheWatcherJudgesBothAndLogsNoText() {
        let s = store()
        var count = 1
        var lines: [String] = []
        var readCalls = 0
        let watcher = ClipboardWatcher(
            changeCount: { count }, types: { ["public.utf8-plain-text"] }, read: { _ in readCalls += 1; return self.text("a private line") },
            frontApp: { ("com.example.Ignored", "Ignored") }, store: s, policy: { .init(ignoredApps: ["com.example.Ignored"]) },
            log: { lines.append($0) }, declaredSource: { ("com.apple.Safari", "Safari") })
        count += 1
        XCTAssertEqual(watcher.poll(), .skipped("ignored app"))
        XCTAssertEqual(readCalls, 0, "nothing was read from an app on the list")
        XCTAssertFalse(lines.contains { $0.contains("private line") })
    }
}
