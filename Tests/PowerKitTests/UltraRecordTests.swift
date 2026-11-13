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

    private func unthrottle(_ pid: Int32) -> UltraRecovery.Action {
        .unthrottle(pid: pid, startTime: member(pid).startTime)
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
        record.lowPowerBefore = false
        record.throttled = [member(10), member(30)]

        // A folder that does not exist yet: the record must still be written.
        let url = directory.appendingPathComponent("not-yet").appendingPathComponent("record.json")
        let store = UltraRecordFile(url: url)
        XCTAssertNil(store.load(), "nothing is there yet")

        XCTAssertTrue(store.save(record))
        XCTAssertEqual(store.load(), record)
        XCTAssertEqual(UltraRecordFile(url: url).load(), record, "a new object reads what the first one wrote")

        record.groups[1].released = true
        XCTAssertTrue(store.save(record))
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
        XCTAssertTrue(store.save(record))
        XCTAssertEqual(store.load(), record)
    }

    func testARecordThatCannotBeSavedSaysSo() throws {
        var record = UltraRecord()
        record.groups = [group("com.example.notes", [20])]

        // The folder the record belongs in is a plain file: it can be neither made nor written into.
        let blocker = directory.appendingPathComponent("blocker")
        try Data("a file".utf8).write(to: blocker)
        let blocked = UltraRecordFile(url: blocker.appendingPathComponent("record.json"))
        XCTAssertFalse(blocked.save(record), "a record that is not on the disk must not be reported as saved")
        XCTAssertNil(blocked.load())

        // The place for the file is a folder.
        let taken = directory.appendingPathComponent("taken", isDirectory: true)
        try FileManager.default.createDirectory(at: taken, withIntermediateDirectories: true)
        XCTAssertFalse(UltraRecordFile(url: taken).save(record))

        // A record that cannot be encoded (a brightness that is not a number) is not saved either, and the record
        // already on disk is left whole.
        let url = directory.appendingPathComponent("record.json")
        let store = UltraRecordFile(url: url)
        XCTAssertTrue(store.save(record))
        var unwritable = record
        unwritable.brightnessBefore = .nan
        XCTAssertFalse(store.save(unwritable))
        XCTAssertEqual(store.load(), record)
    }

    /// A record written by a build that had no efficiency-cores part has no such key. It must still load, or a session that
    /// build left behind could not be undone by this one.
    func testARecordWrittenBeforeTheEfficiencyCoresPartStillLoadsAndLiftsNothing() throws {
        let old = #"{"groups":[{"id":"com.example.notes","name":"Notes","members":[{"pid":20,"startTime":200}],"released":false}],"#
            + #""brightnessBefore":0.8,"rateLowered":true}"#
        let url = directory.appendingPathComponent("old.json")
        try Data(old.utf8).write(to: url)
        let record = try XCTUnwrap(UltraRecordFile(url: url).load(), "an old record is still a record")
        XCTAssertNil(record.throttled)
        XCTAssertEqual(record.groups.map(\.id), ["com.example.notes"])
        XCTAssertEqual(UltraRecovery.actions(for: record, brightnessNow: 0.25),
                       [.resume(pid: 20, startTime: 200), .brightness(0.8), .restoreRate])
    }

    /// A record written by a build that did not name whether Low Power Mode was on before the session has no such key. It must
    /// still load, as "not known", or a session that build left behind could not be undone by this one.
    func testARecordWrittenBeforeLowPowerWasNamedStillLoadsWithoutIt() throws {
        let old = #"{"groups":[],"brightnessBefore":0.8,"rateLowered":false,"powerModeBefore":0}"#
        let url = directory.appendingPathComponent("old.json")
        try Data(old.utf8).write(to: url)
        let record = try XCTUnwrap(UltraRecordFile(url: url).load(), "an old record is still a record")
        XCTAssertNil(record.lowPowerBefore)
        XCTAssertEqual(record.powerModeBefore, 0)
        XCTAssertNil(UltraRecord().lowPowerBefore, "nothing is named until the mode names it")
    }

    func testWhetherLowPowerWasOnBeforeRoundTripsThroughAFile() {
        let store = UltraRecordFile(url: directory.appendingPathComponent("record.json"))
        for value: Bool? in [true, false, nil] {
            var record = UltraRecord()
            record.lowPowerBefore = value
            XCTAssertTrue(store.save(record))
            XCTAssertEqual(store.load()?.lowPowerBefore, value)
        }
    }

    /// Putting the screen back has to wait for Low Power Mode to be off when the mode is what switched it on (it was not the
    /// owner's own) and there is a screen to put back: macOS raises the screen when Low Power Mode ends, by an amount that
    /// depends on the level, so a level set before that is lost.
    func testTheScreenWaitsForLowPowerOnlyWhenTheModeSwitchedItOnAndThereIsAScreenToPutBack() {
        var record = UltraRecord()
        XCTAssertFalse(record.waitsForLowPowerToEnd, "nothing was done")
        record.brightnessBefore = 0.8
        XCTAssertFalse(record.waitsForLowPowerToEnd, "no helper: Low Power Mode was never switched on by the mode")
        record.powerModeBefore = 0
        XCTAssertTrue(record.waitsForLowPowerToEnd, "a record from before it was named: not known to be the owner's own")
        record.lowPowerBefore = false
        XCTAssertTrue(record.waitsForLowPowerToEnd)
        record.lowPowerBefore = true
        XCTAssertFalse(record.waitsForLowPowerToEnd, "it was the owner's own, and stays on")
        record.lowPowerBefore = false
        record.brightnessBefore = nil
        XCTAssertFalse(record.waitsForLowPowerToEnd, "nothing to put back, so nothing to wait for")
    }

    func testTheProcessesPutUnderThePolicyRoundTripThroughAFile() {
        var record = UltraRecord()
        XCTAssertNil(record.throttled, "nothing named until the mode names something")
        record.throttled = [member(10), member(11)]
        let store = UltraRecordFile(url: directory.appendingPathComponent("record.json"))
        XCTAssertTrue(store.save(record))
        XCTAssertEqual(store.load()?.throttled, [member(10), member(11)])
        record.throttled = []
        XCTAssertTrue(store.save(record))
        XCTAssertEqual(store.load()?.throttled, [], "a list with nothing in it is not the same as no list, and both lift nothing")
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

        let actions = UltraRecovery.actions(for: record, brightnessNow: 0.25)
        // Every process is continued before anything that has to ask another app to do something, and before settings.
        XCTAssertEqual(actions, [resume(20), resume(21), resume(30), resume(40),
                                 .unhide(pid: 20), .unhide(pid: 30),
                                 .brightness(0.8), .restoreRate, .keyboard(0.35), .powerMode(1)])
    }

    /// The policy comes off every process the record names, after every continue (a process that is stopped cannot be
    /// helped by it, and that is the part that must not wait) and before anything is unhidden or any setting is put back.
    func testThePolicyIsLiftedAfterTheContinuesAndBeforeTheUnhide() {
        var record = UltraRecord()
        record.groups = [group("com.example.notes", [20, 21], appPID: 20),
                         group("com.example.mail", [30], appPID: 30)]
        record.throttled = [member(10), member(11), member(40)]
        record.brightnessBefore = 0.8
        record.rateLowered = true
        record.keyboardBefore = 0.35
        record.powerModeBefore = 1

        XCTAssertEqual(UltraRecovery.actions(for: record, brightnessNow: 0.25),
                       [resume(20), resume(21), resume(30),
                        unthrottle(10), unthrottle(11), unthrottle(40),
                        .unhide(pid: 20), .unhide(pid: 30),
                        .brightness(0.8), .restoreRate, .keyboard(0.35), .powerMode(1)])
    }

    /// Whatever the record names is lifted, whether or not the group it came from was released: a released group is the very
    /// one that was put under the policy when it came back.
    func testAReleasedGroupIsNotContinuedAgainButWhatWasPutUnderThePolicyIsLifted() {
        var record = UltraRecord()
        record.groups = [group("com.example.sync", [10, 11], released: true)]
        record.throttled = [member(10), member(11)]
        XCTAssertEqual(UltraRecovery.actions(for: record, brightnessNow: nil), [unthrottle(10), unthrottle(11)])
    }

    func testARecordThatNamesNothingUnderThePolicyLiftsNothing() {
        var record = UltraRecord()
        record.groups = [group("com.example.notes", [20])]
        XCTAssertEqual(UltraRecovery.actions(for: record, brightnessNow: nil), [resume(20)])
        record.throttled = []
        XCTAssertEqual(UltraRecovery.actions(for: record, brightnessNow: nil), [resume(20)])
    }

    func testNothingChangedMeansNothingRestored() {
        var record = UltraRecord()
        record.groups = [group("com.example.notes", [20, 21])]
        XCTAssertNil(record.brightnessBefore)
        XCTAssertFalse(record.rateLowered)
        XCTAssertNil(record.keyboardBefore)
        XCTAssertNil(record.powerModeBefore)

        // The screen reads a quarter, but the mode never lowered it: it is not the mode's to touch.
        XCTAssertEqual(UltraRecovery.actions(for: record, brightnessNow: 0.25), [resume(20), resume(21)])
        XCTAssertEqual(UltraRecovery.actions(for: UltraRecord(), brightnessNow: 0.25), [])
    }

    func testBrightnessIsRestoredThroughTheCeilingRule() {
        var record = UltraRecord()
        record.brightnessBefore = 0.8

        XCTAssertEqual(UltraRecovery.actions(for: record, brightnessNow: 0.25), [.brightness(0.8)],
                       "still at the ceiling: the mode's doing, so it is put back")
        XCTAssertEqual(UltraRecovery.actions(for: record, brightnessNow: 0.2184), [.brightness(0.8)],
                       "dimmer than the ceiling, as macOS leaves it with Low Power Mode on: put back to what it was before the mode")
        XCTAssertEqual(UltraRecovery.actions(for: record, brightnessNow: 0.9), [],
                       "above the ceiling: somebody else raised it, so it is not the mode's to change")
        XCTAssertEqual(UltraRecovery.actions(for: record, brightnessNow: 0.8), [],
                       "already at the earlier level: never lowered at the end")
        XCTAssertEqual(UltraRecovery.actions(for: record, brightnessNow: nil), [],
                       "unreadable: no way to tell where it is")
    }
}
