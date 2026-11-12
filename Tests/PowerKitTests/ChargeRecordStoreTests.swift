import XCTest
import Darwin
@testable import PowerKit

/// The one record of macOS's own charge settings for the whole Mac, and the list of who holds the limit.
///
/// Every test uses a temporary folder: none may touch `/Users/Shared`. Which pids are alive is a set the test owns,
/// except where the test is about reading a real process.
final class ChargeRecordStoreTests: XCTestCase {

    private var directory: String!
    private var live: Set<Int32> = []

    private let original = NativeChargeState(mclEnabled: true, mclLimit: 90, optimizedChargingEnabled: true)

    override func setUpWithError() throws {
        directory = NSTemporaryDirectory() + "cc-store-\(UUID().uuidString.prefix(8))/Anode"
        try FileManager.default.createDirectory(atPath: (directory as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        live = []
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: (directory as NSString).deletingLastPathComponent)
    }

    private func store(uid: UInt32, pid: Int32, lockTimeout: TimeInterval = 3) -> ChargeRecordStore {
        live.insert(pid)
        return ChargeRecordStore(directory: directory, uid: uid, pid: pid,
                                 isLive: { [unowned self] in live.contains($0) }, lockTimeout: lockTimeout)
    }

    private func contents(_ s: ChargeRecordStore) -> ChargeRecordStore.Contents? { s.peek() }

    private func holders(_ s: ChargeRecordStore) -> [ChargeHolder] {
        if case .record(let r)? = s.peek() { return r.holders }
        return []
    }

    // ── What is read from the file is validated ─────────────────────────────

    private func parse(_ json: String) -> ChargeRecordStore.Contents { ChargeRecordStore.parse(Data(json.utf8)) }

    private func record(mclLimit: Int = 90, holders: String = #"[{"uid":501,"pid":1234}]"#,
                        version: Int = 1) -> String {
        #"{"version":\#(version),"original":{"mclEnabled":true,"mclLimit":\#(mclLimit),"#
            + #""optimizedChargingEnabled":false},"holders":\#(holders)}"#
    }

    func testAnEmptyFileIsNoRecord() {
        XCTAssertEqual(ChargeRecordStore.parse(Data()), .none)
    }

    func testARecordIsRead() {
        XCTAssertEqual(parse(record()), .record(SharedChargeRecord(
            original: NativeChargeState(mclEnabled: true, mclLimit: 90, optimizedChargingEnabled: false),
            holders: [ChargeHolder(uid: 501, pid: 1234)])))
        // Unknown extra keys are ignored; duplicates are one holder.
        let twice = #"[{"uid":501,"pid":1234},{"uid":501,"pid":1234}]"#
        guard case .record(let r) = parse(record(holders: twice)) else { return XCTFail() }
        XCTAssertEqual(r.holders.count, 1)
        XCTAssertEqual(parse(record(holders: "[]")), .record(SharedChargeRecord(
            original: NativeChargeState(mclEnabled: true, mclLimit: 90, optimizedChargingEnabled: false), holders: [])))
    }

    /// Anything else is not a record: a limit outside 20…100, a holder that is not a user and a process, too many
    /// holders, a version this Anode does not know, text, a file too big to be one.
    func testWhatIsNotARecordIsNotOne() {
        let bad: [String] = [
            record(mclLimit: 19), record(mclLimit: 101), record(mclLimit: -1), record(version: 2),
            record(holders: #"[{"uid":-1,"pid":10}]"#), record(holders: #"[{"uid":501,"pid":-5}]"#),
            record(holders: #"[{"uid":501,"pid":99999999}]"#), record(holders: #"[{"uid":501}]"#),
            record(holders: #"[{"uid":"501","pid":10}]"#), record(holders: #"{"uid":501}"#),
            record(holders: "[" + (1...65).map { #"{"uid":\#($0),"pid":\#($0)}"# }.joined(separator: ",") + "]"),
            #"{"version":1,"holders":[]}"#, #"{"version":1,"original":{"mclLimit":90},"holders":[]}"#,
            "not json", "[1,2,3]", "{}",
        ]
        for text in bad {
            guard case .unreadable = parse(text) else { return XCTFail("taken for a record: \(text)") }
        }
        guard case .unreadable = ChargeRecordStore.parse(Data(repeating: 0x20, count: ChargeRecordStore.maxBytes + 1))
        else { return XCTFail("a file too big to be a record was read") }
    }

    func testWhatIsWrittenIsWhatIsRead() throws {
        let r = SharedChargeRecord(original: original,
                                   holders: [ChargeHolder(uid: 501, pid: 7), ChargeHolder(uid: 502, pid: 0)])
        let data = try XCTUnwrap(ChargeRecordStore.encode(r))
        XCTAssertEqual(ChargeRecordStore.parse(data), .record(r))
    }

    // ── Who is live ─────────────────────────────────────────────────────────

    func testOnlyAnodesAppBinaryIsAnAnode() {
        let installed = "/Users/someone/Applications/Anode.app/Contents/MacOS/AnodeApp"
        XCTAssertTrue(ChargeHolderLiveness.isAnodeBinary(path: installed))
        XCTAssertTrue(ChargeHolderLiveness.isAnodeBinary(path: "/Applications/Anode.app/Contents/MacOS/AnodeApp"))
        for other in ["/bin/sleep", "/sbin/launchd", "/tmp/AnodeApp",
                      "/Applications/Anode.app/Contents/MacOS/AnodeHelper",
                      "/Applications/Anode.app/Contents/MacOS/AnodeApp2", ""] {
            XCTAssertFalse(ChargeHolderLiveness.isAnodeBinary(path: other), other)
        }
    }

    /// Measured, and kept as a test: as an ordinary user the path of another user's process can be read. launchd is
    /// root's, and it is not Anode.
    func testAnotherUsersProcessCanBeIdentifiedWithoutPrivilege() {
        XCTAssertNotEqual(getuid(), 0, "this test is about an ordinary user reading root's process")
        XCTAssertEqual(ChargeHolderLiveness.executablePath(of: 1), "/sbin/launchd")
        XCTAssertFalse(ChargeHolderLiveness.isLiveAnode(pid: 1))
    }

    /// A pid that now belongs to something else is not a live holder: this very process is running, and is the test
    /// runner. So is no pid, a negative one, and one that does not exist.
    func testAPidThatBelongsToSomethingElseIsNotALiveHolder() {
        XCTAssertNotNil(ChargeHolderLiveness.executablePath(of: getpid()))
        XCTAssertFalse(ChargeHolderLiveness.isLiveAnode(pid: getpid()))
        XCTAssertFalse(ChargeHolderLiveness.isLiveAnode(pid: 0))
        XCTAssertFalse(ChargeHolderLiveness.isLiveAnode(pid: -1))
        XCTAssertFalse(ChargeHolderLiveness.isLiveAnode(pid: 999_999))
        // Through the store, with the real check: a record whose holders are those pids is held by nobody.
        let me = ChargeRecordStore(directory: directory, uid: 501, pid: 4242)
        let stale = SharedChargeRecord(original: original, holders: [ChargeHolder(uid: 502, pid: getpid()),
                                                                     ChargeHolder(uid: 503, pid: 1)])
        XCTAssertTrue(me.liveOthers(stale).isEmpty)
        XCTAssertTrue(me.looksUnclean(stale))
    }

    /// A process whose executable is Anode's app binary is a live holder; one that has exited is not. The process is a
    /// copy of `/bin/sleep` signed ad hoc and placed where the app's binary would be.
    func testARunningAnodeIsALiveHolderUntilItExits() throws {
        let bundle = (directory as NSString).deletingLastPathComponent + "/Anode.app/Contents/MacOS"
        try FileManager.default.createDirectory(atPath: bundle, withIntermediateDirectories: true)
        let binary = bundle + "/AnodeApp"
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: binary)
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", binary]
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        guard sign.terminationStatus == 0 else { throw XCTSkip("codesign is not available here") }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["30"]
        try p.run()
        let pid = p.processIdentifier
        defer { if p.isRunning { p.terminate() } }
        // Resolved symlinks: the temporary folder may be reached through /var, which is /private/var.
        let path = try XCTUnwrap(ChargeHolderLiveness.executablePath(of: pid))
        XCTAssertTrue(path.hasSuffix("/Anode.app/Contents/MacOS/AnodeApp"), path)
        XCTAssertTrue(ChargeHolderLiveness.isLiveAnode(pid: pid))
        p.terminate()
        p.waitUntilExit()
        XCTAssertFalse(ChargeHolderLiveness.isLiveAnode(pid: pid), "an exited Anode was a live holder")
    }

    // ── Switching on ────────────────────────────────────────────────────────

    func testSwitchingOnWithNoRecordWritesMacOSsSettingsWithThisAccountTheOnlyHolder() {
        let a = store(uid: 501, pid: 100)
        XCTAssertEqual(a.acquire(readMacOS: { self.original }), .recorded(original))
        XCTAssertEqual(contents(a), .record(SharedChargeRecord(original: original, holders: [a.me])))
    }

    /// The file and the folder are open to every account, and the folder is sticky: the next account must be able to
    /// write what this one made, and nobody can remove it.
    func testTheFileAndFolderAreOpenToEveryAccount() throws {
        let a = store(uid: 501, pid: 100)
        _ = a.acquire(readMacOS: { self.original })
        var info = stat()
        XCTAssertEqual(stat(a.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o666)
        XCTAssertEqual(stat(directory, &info), 0)
        XCTAssertEqual(info.st_mode & 0o7777, 0o1777)
    }

    /// A record that is there is adopted, whoever holds it: what macOS says now is that Anode's limit.
    func testSwitchingOnAdoptsARecordAlreadyThereAndDoesNotReadMacOS() {
        let a = store(uid: 501, pid: 100)
        let b = store(uid: 502, pid: 200)
        _ = a.acquire(readMacOS: { self.original })
        let theirs = NativeChargeState(mclEnabled: true, mclLimit: 85, optimizedChargingEnabled: false)
        var asked = false
        XCTAssertEqual(b.acquire(readMacOS: { asked = true; return theirs }), .adopted(original))
        XCTAssertFalse(asked, "macOS was read and its settings, A's limit, were taken for its own")
        XCTAssertEqual(holders(b), [a.me, b.me])
        if case .record(let r)? = b.peek() { XCTAssertEqual(r.original, original) } else { XCTFail() }
    }

    /// Only stale holders: an Anode died holding the limit. Its record is the original; the stale holders go.
    func testSwitchingOnAdoptsARecordWithOnlyStaleHoldersAndDropsThem() {
        let a = store(uid: 501, pid: 100)
        _ = a.acquire(readMacOS: { self.original })
        live.remove(100)
        let b = store(uid: 502, pid: 200)
        XCTAssertEqual(b.acquire(readMacOS: { XCTFail("read macOS"); return nil }), .adopted(original))
        XCTAssertEqual(holders(b), [b.me])
    }

    /// The same account again under a new process replaces its old entry.
    func testSwitchingOnAgainReplacesThisAccountsOldEntry() {
        let a = store(uid: 501, pid: 100)
        _ = a.acquire(readMacOS: { self.original })
        let again = store(uid: 501, pid: 101)
        _ = again.acquire(readMacOS: { nil })
        XCTAssertEqual(holders(again), [again.me])
    }

    func testSwitchingOnWithNoRecordAndAMacOSThatWillNotSayWritesNothing() {
        let a = store(uid: 501, pid: 100)
        XCTAssertEqual(a.acquire(readMacOS: { nil }), .macOSUnreadable)
        XCTAssertEqual(contents(a), ChargeRecordStore.Contents.none)
    }

    /// A file that is not a record is taken for none: macOS is read and the file is written over.
    func testSwitchingOnOverAFileThatIsNotARecordWritesOneAnew() throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try "not a record".write(toFile: directory + "/" + ChargeRecordStore.fileName, atomically: false,
                                 encoding: .utf8)
        let a = store(uid: 501, pid: 100)
        guard case .unreadable? = a.peek() else { return XCTFail() }
        XCTAssertEqual(a.acquire(readMacOS: { self.original }), .recorded(original))
        XCTAssertEqual(contents(a), .record(SharedChargeRecord(original: original, holders: [a.me])))
    }

    // ── Putting back ────────────────────────────────────────────────────────

    func testTheLastLiveHolderPutsMacOSBackAndClearsTheRecord() {
        let a = store(uid: 501, pid: 100)
        _ = a.acquire(readMacOS: { self.original })
        var restored: NativeChargeState??
        XCTAssertEqual(a.release(restore: { restored = .some($0); return true }), .restored(true))
        XCTAssertEqual(restored, .some(.some(original)))
        XCTAssertEqual(contents(a), ChargeRecordStore.Contents.none)
    }

    func testARestoreThatDidNotWorkKeepsTheRecordWithNobodyHoldingIt() {
        let a = store(uid: 501, pid: 100)
        _ = a.acquire(readMacOS: { self.original })
        XCTAssertEqual(a.release(restore: { _ in false }), .restored(false))
        XCTAssertEqual(contents(a), .record(SharedChargeRecord(original: original, holders: [])))
        // The next launch of anyone's Anode takes it for an unclean exit.
        let b = store(uid: 502, pid: 200)
        if case .record(let r)? = b.peek() { XCTAssertTrue(b.looksUnclean(r)) } else { XCTFail() }
    }

    /// Another account's Anode is running and holds it: nothing is put back, and this account is no longer a holder.
    func testAHolderThatIsNotTheLastPutsNothingBack() {
        let a = store(uid: 501, pid: 100)
        let b = store(uid: 502, pid: 200)
        _ = a.acquire(readMacOS: { self.original })
        _ = b.acquire(readMacOS: { nil })
        XCTAssertEqual(b.release(restore: { _ in XCTFail("put back over another account's limit"); return true }),
                       .handedOver)
        XCTAssertEqual(holders(a), [a.me])
        // Then the other one is the last.
        var restored = false
        XCTAssertEqual(a.release(restore: { _ in restored = true; return true }), .restored(true))
        XCTAssertTrue(restored)
        XCTAssertEqual(contents(a), ChargeRecordStore.Contents.none)
    }

    /// The other holder died: it is stale, and this account is the last live one.
    func testAStaleHolderDoesNotKeepTheLimit() {
        let a = store(uid: 501, pid: 100)
        let b = store(uid: 502, pid: 200)
        _ = a.acquire(readMacOS: { self.original })
        _ = b.acquire(readMacOS: { nil })
        live.remove(100)
        var restored = false
        XCTAssertEqual(b.release(restore: { _ in restored = true; return true }), .restored(true))
        XCTAssertTrue(restored)
    }

    func testPuttingBackFromAFileThatIsNotARecordPutsNothingBack() throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let file = directory + "/" + ChargeRecordStore.fileName
        try "garbage".write(toFile: file, atomically: false, encoding: .utf8)
        let a = store(uid: 501, pid: 100)
        guard case .unreadable? = a.release(restore: { _ in XCTFail("put back from garbage"); return true }) else {
            return XCTFail()
        }
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), "garbage", "the file was changed")
    }

    /// An empty file while Charge Control is on: the record was lost. The restore is asked, with nothing.
    func testPuttingBackWithNoRecordSaysSo() {
        let a = store(uid: 501, pid: 100)
        _ = a.acquire(readMacOS: { self.original })
        _ = a.release(restore: { _ in true })
        var got: NativeChargeState??
        XCTAssertEqual(a.release(restore: { got = .some($0); return true }), .restored(true))
        XCTAssertEqual(got, .some(nil))
    }

    // ── Which runs did not release ──────────────────────────────────────────

    func testWhichRecordsLookLikeAnUncleanExit() {
        let me = store(uid: 501, pid: 100)
        _ = store(uid: 502, pid: 200)
        func unclean(_ holders: [ChargeHolder]) -> Bool {
            me.looksUnclean(SharedChargeRecord(original: original, holders: holders))
        }
        XCTAssertFalse(unclean([me.me]), "this process is a holder of its own record")
        XCTAssertFalse(unclean([ChargeHolder(uid: 502, pid: 200)]), "another account's Anode is running")
        XCTAssertFalse(unclean([me.me, ChargeHolder(uid: 502, pid: 200)]))
        XCTAssertTrue(unclean([ChargeHolder(uid: 501, pid: 99)]), "this account under a process that is gone")
        XCTAssertTrue(unclean([ChargeHolder(uid: 502, pid: 99)]), "nobody alive")
        XCTAssertTrue(unclean([]), "nobody at all")
        XCTAssertTrue(unclean([ChargeHolder(uid: 501, pid: 99), ChargeHolder(uid: 502, pid: 200)]),
                      "this account's own entry under another process, whoever else is running")
        XCTAssertTrue(unclean([ChargeHolder(uid: 501, pid: 0)]), "a holder with no known process is stale")
    }

    // ── An earlier build's record ───────────────────────────────────────────

    func testAnEarlierBuildsRecordIsMovedInWithAHolderThatIsNotRunning() {
        let a = store(uid: 501, pid: 100)
        XCTAssertTrue(a.adopt(legacy: original))
        let want = SharedChargeRecord(original: original, holders: [ChargeHolder(uid: 501, pid: 0)])
        XCTAssertEqual(contents(a), .record(want))
        if case .record(let r)? = a.peek() { XCTAssertTrue(a.looksUnclean(r)) } else { XCTFail() }
        // A record already there is not replaced by it.
        let other = NativeChargeState(mclEnabled: false, mclLimit: 100, optimizedChargingEnabled: true)
        XCTAssertTrue(a.adopt(legacy: other))
        XCTAssertEqual(contents(a), .record(want))
    }

    // ── A folder that cannot be had ─────────────────────────────────────────

    func testAFolderThatCannotBeMadeIsUnusable() throws {
        let blocker = (directory as NSString).deletingLastPathComponent + "/blocker"
        try "x".write(toFile: blocker, atomically: true, encoding: .utf8)   // a file where the folder would be
        let s = ChargeRecordStore(directory: blocker + "/Anode", uid: 501, pid: 100, isLive: { _ in true })
        XCTAssertFalse(s.isUsable())
        XCTAssertNil(s.acquire(readMacOS: { self.original }))
        XCTAssertNil(s.release(restore: { _ in true }))
    }

    func testAReadOnlyFolderIsUnusable() throws {
        let parent = (directory as NSString).deletingLastPathComponent + "/readonly"
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(parent, 0o555), 0)
        defer { _ = chmod(parent, 0o755) }
        let s = ChargeRecordStore(directory: parent + "/Anode", uid: 501, pid: 100, isLive: { _ in true })
        XCTAssertFalse(s.isUsable())
    }

    // ── Two at once ─────────────────────────────────────────────────────────

    /// Every writer reads the file, changes it and writes it back. Without the lock two of them read the same
    /// holders and one loses its entry. Each thread opens the file itself, as each account's process does, so they
    /// exclude one another by the lock alone.
    func testWritersAtOnceDoNotLoseAHolder() {
        let count = 16
        let stores = (0..<count).map { store(uid: UInt32(1000 + $0), pid: Int32(5000 + $0)) }
        let group = DispatchGroup()
        for s in stores {
            group.enter()
            DispatchQueue.global().async {
                for _ in 0..<10 { _ = s.acquire(readMacOS: { self.original }) }
                group.leave()
            }
        }
        group.wait()
        let final = holders(stores[0])
        XCTAssertEqual(Set(final.map(\.uid)), Set(stores.map(\.me.uid)), "a holder was lost: \(final)")
    }

    /// A lock that cannot be had in time (a process stopped while it holds it) is a store that cannot be used, not a
    /// hang of the main thread.
    func testALockHeldByAnotherIsWaitedForOnlyBrieflyThenGivenUpOn() throws {
        let a = store(uid: 501, pid: 100, lockTimeout: 0.2)
        _ = a.acquire(readMacOS: { self.original })
        let fd = open(a.path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX), 0)
        let start = Date()
        XCTAssertNil(a.acquire(readMacOS: { self.original }))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        flock(fd, LOCK_UN)
        XCTAssertNotNil(a.acquire(readMacOS: { self.original }))
    }
}
