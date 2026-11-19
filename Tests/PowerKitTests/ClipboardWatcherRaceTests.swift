import XCTest
@testable import PowerKit

/// The clipboard can change between the watcher looking at the type strings and its reading the contents. What is read then may be
/// a copy whose types were never checked, so it is dropped, and the next look takes the new copy from the start.
final class ClipboardWatcherRaceTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("anode-clip-race-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func text(_ s: String) -> [ClipboardRepresentation] {
        [ClipboardRepresentation(item: 0, type: "public.utf8-plain-text", data: Data(s.utf8))]
    }

    func testACopyThatChangesWhileItIsReadIsDroppedAndTheNextOneIsTaken() {
        let store = ClipboardStore(directory: directory, limits: .init(maxEntries: 50, maxEntryBytes: 1_000_000, maxTotalBytes: 10_000_000, maxAge: nil))
        var count = 1
        var types = ["public.utf8-plain-text"]
        var contents = text("the first copy")
        var lines: [String] = []
        var raceOnce = true
        let watcher = ClipboardWatcher(
            changeCount: { count }, types: { types },
            read: { _ in
                // Another app copies something private right now, after the types were looked at.
                if raceOnce {
                    raceOnce = false
                    count += 1
                    contents = self.text("a private second copy")
                    types = ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]
                }
                return contents
            },
            frontApp: { ("com.example.Editor", "Editor") }, store: store, policy: { .init() }, log: { lines.append($0) })
        count += 1                                                    // the first copy lands
        XCTAssertEqual(watcher.poll(), .skipped("changed while it was read"))
        XCTAssertTrue(store.entries.isEmpty, "a mix of two copies was recorded")
        XCTAssertTrue(lines.contains { $0.contains("changed while it was read") })
        // The next look sees the new counter and the new types: the second copy is concealed, and is not recorded either.
        XCTAssertEqual(watcher.poll(), .skipped("concealed"))
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(lines.contains { $0.contains("private") }, "the log held what was copied")
    }

    func testAnOrdinaryCopyIsStillRecordedWhenNothingMovesWhileItIsRead() {
        let store = ClipboardStore(directory: directory, limits: .init(maxEntries: 50, maxEntryBytes: 1_000_000, maxTotalBytes: 10_000_000, maxAge: nil))
        var count = 1
        let watcher = ClipboardWatcher(changeCount: { count }, types: { ["public.utf8-plain-text"] }, read: { _ in self.text("hello") },
                                       frontApp: { ("com.example.Editor", "Editor") }, store: store, policy: { .init() }, log: { _ in })
        count += 1
        if case .recorded(.added) = watcher.poll() {} else { XCTFail("not recorded") }
        XCTAssertEqual(store.entries.map(\.preview), ["hello"])
    }

    /// The marker read as its presence alone (no data) is enough for the store's own check to refuse the copy.
    func testAMarkerReadWithNoDataStillRefusesTheCopyInTheStore() {
        let store = ClipboardStore(directory: directory, limits: .init(maxEntries: 50, maxEntryBytes: 1_000_000, maxTotalBytes: 10_000_000, maxAge: nil))
        let reps = text("a password") + [ClipboardRepresentation(item: 0, type: "org.nspasteboard.ConcealedType", data: Data())]
        XCTAssertEqual(store.add(ClipboardSnapshot(representations: reps, sourceBundleID: "com.example.Editor")), .skipped("concealed"))
        XCTAssertTrue(store.entries.isEmpty)
    }
}
