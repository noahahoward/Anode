import XCTest
@testable import PowerKit

/// The record Ultra Low Power Mode keeps on disk, and what undoes a session Anode did not end.
///
/// The file tests use a folder of their own under the temporary directory, named for the test run and removed after
/// it: none may touch the real record's path. Recovery is a pure function of the record, so nothing here signals a
/// process or changes a setting.
final class UltraRecordTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ultra-record-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Only the folder this test made.
        try? FileManager.default.removeItem(at: directory)
    }

    // ── Fixtures ────────────────────────────────────────────────────────────

    /// The start time follows the pid so two members never look alike.
    private func member(_ pid: Int32) -> UltraRecord.Member {
        UltraRecord.Member(pid: pid, startTime: 1_700_000_000_000_000 + UInt64(pid))
    }

    private func group(_ id: String, _ pids: [Int32], appPID: Int32? = nil, released: Bool = false) -> UltraRecord.Group {
        UltraRecord.Group(id: id, name: id.capitalized, members: pids.map(member), appPID: appPID, released: released)
    }

    private func resume(_ pid: Int32) -> UltraRecovery.Action {
        .resume(pid: pid, startTime: member(pid).startTime)
    }

    // ── The file ────────────────────────────────────────────────────────────

    func testRecordRoundTripsThroughAFile() {
        // Every field away from its default, so a field that is dropped on the way is seen.
        var record = UltraRecord()
        record.groups = [group("com.example.sync", [30, 31], appPID: 30, released: true),
                         group("com.example.notes", [40])]
        record.brightnessBefore = 0.8
        record.rateLowered = true
        record.keyboardBefore = 0.35
        record.powerModeBefore = 1

        // A folder that does not exist yet: the record must still be written.
        let url = directory.appendingPathComponent("not-yet").appendingPathComponent("record.json")
        let store = UltraRecordFile(url: url)
        XCTAssertNil(store.load(), "nothing is there yet")

        store.save(record)
        XCTAssertEqual(store.load(), record)
        XCTAssertEqual(UltraRecordFile(url: url).load(), record, "a new object reads what the first one wrote")

        record.groups[1].released = true
        store.save(record)
        XCTAssertEqual(store.load(), record, "a second save replaces the first")

        store.clear()
        XCTAssertNil(store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        store.clear() // nothing there: no harm
    }

    func testGarbageFileLoadsAsNoRecord() throws {
        let url = directory.appendingPathComponent("record.json")
        let store = UltraRecordFile(url: url)

        try Data("this is not a record {".utf8).write(to: url)
        XCTAssertNil(store.load())

        try Data().write(to: url)
        XCTAssertNil(store.load(), "an empty file")

        try Data(#"{"groups":"no"}"#.utf8).write(to: url)
        XCTAssertNil(store.load(), "valid JSON that is not a record")

        // It is not stuck: a good record replaces the garbage.
        var record = UltraRecord()
        record.rateLowered = true
        store.save(record)
        XCTAssertEqual(store.load(), record)
    }

    // ── Undoing a session ───────────────────────────────────────────────────

    func testRecoveryContinuesOnlyWhatTheRecordNames() {
        var record = UltraRecord()
        record.groups = [group("com.example.sync", [10, 11], appPID: 10, released: true),
                         group("com.example.notes", [20, 21], appPID: 20)]

        XCTAssertEqual(UltraRecovery.actions(for: record, brightnessNow: nil),
                       [resume(20), resume(21), .unhide(pid: 20)])
    }

    func testProcessesComeBeforeSettings() {
        var record = UltraRecord()
        record.groups = [group("com.example.notes", [20, 21], appPID: 20),
                         group("com.example.mail", [30], appPID: 30),
                         group("com.example.tool", [40])]
        record.brightnessBefore = 0.8
        record.rateLowered = true
        record.keyboardBefore = 0.35
        record.powerModeBefore = 1

        let actions = UltraRecovery.actions(for: record, brightnessNow: 0.5)
        // Every process is continued before anything that has to ask another app to do something, and before settings.
        XCTAssertEqual(actions, [resume(20), resume(21), resume(30), resume(40),
                                 .unhide(pid: 20), .unhide(pid: 30),
                                 .brightness(0.8), .restoreRate, .keyboard(0.35), .powerMode(1)])
    }

    func testNothingChangedMeansNothingRestored() {
        var record = UltraRecord()
        record.groups = [group("com.example.notes", [20, 21])]
        XCTAssertNil(record.brightnessBefore)
        XCTAssertFalse(record.rateLowered)
        XCTAssertNil(record.keyboardBefore)
        XCTAssertNil(record.powerModeBefore)

        // The screen reads half, but the mode never lowered it: it is not the mode's to touch.
        XCTAssertEqual(UltraRecovery.actions(for: record, brightnessNow: 0.5), [resume(20), resume(21)])
        XCTAssertEqual(UltraRecovery.actions(for: UltraRecord(), brightnessNow: 0.5), [])
    }

    func testBrightnessIsRestoredThroughTheCeilingRule() {
        var record = UltraRecord()
        record.brightnessBefore = 0.8

        XCTAssertEqual(UltraRecovery.actions(for: record, brightnessNow: 0.5), [.brightness(0.8)],
                       "still at the ceiling: the mode's doing, so it is put back")
        XCTAssertEqual(UltraRecovery.actions(for: record, brightnessNow: 0.3), [],
                       "the owner went dimmer since: left alone")
        XCTAssertEqual(UltraRecovery.actions(for: record, brightnessNow: nil), [],
                       "unreadable: no way to tell the owner did not go dimmer")
    }
}
