import XCTest
@testable import AnodeApp
@testable import PowerKit

/// Two accounts' Anodes on one Mac, sharing the one record of macOS's own settings.
///
/// macOS's charge limit is one setting for the whole Mac, and each account runs its own Anode with its own
/// preferences. Here there is one `FakeChargeLimitClient` (macOS itself), one record file in a temporary folder
/// (never `/Users/Shared`), a set of pids that are running, and an account per user: its own settings, its own
/// helper link, its own notification center. A launch is what `main.swift` does: the lift at the top of the program,
/// then the controller. The old failure: A holds 85 and goes to the background, B cold-starts and records A's limit as
/// "macOS's own", both quit, B puts A's limit back, A (not on screen) puts nothing back, and macOS is left at 85 with
/// no Anode running.
final class ChargeSharedRecordTests: XCTestCase {

    private final class Account {
        let name: String
        let uid: UInt32
        var pid: Int32
        let defaults: UserDefaults
        let suite: String
        let settings: Settings
        let helper = FakeHelperLink()
        let center = NotificationCenter()
        var lines: [String] = []
        var battery = ChargeControllerTests.state(70)
        var records: ChargeRecords!
        var controller: ChargeController?

        init(name: String, uid: UInt32, pid: Int32, test: String) throws {
            self.name = name
            self.uid = uid
            self.pid = pid
            (defaults, suite) = try TestDefaults.make(owner: "ChargeShared.\(name)", test: test)
            settings = Settings(defaults: defaults)
        }
    }

    /// macOS before any Anode: no limit, Optimized Battery Charging on.
    private let macOSOwn = NativeChargeState(mclEnabled: false, mclLimit: 100, optimizedChargingEnabled: true)

    private var directory: String!
    private var macOS: FakeChargeLimitClient!
    private var live: Set<Int32> = []
    private var accounts: [Account] = []
    private var nextPid: Int32 = 1000

    override func setUpWithError() throws {
        directory = NSTemporaryDirectory() + "cc-shared-\(UUID().uuidString.prefix(8))/Anode"
        try FileManager.default.createDirectory(atPath: (directory as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        macOS = FakeChargeLimitClient(state: macOSOwn)
        live = []
        accounts = []
        nextPid = 1000
    }

    override func tearDownWithError() throws {
        for a in accounts {
            a.controller?.shutdown()
            a.controller = nil
            TestDefaults.destroy(a.defaults, a.suite)
        }
        try? FileManager.default.removeItem(atPath: (directory as NSString).deletingLastPathComponent)
    }

    // ── The Mac ─────────────────────────────────────────────────────────────

    private func account(_ name: String, uid: UInt32, limit: Int) throws -> Account {
        let a = try Account(name: name, uid: uid, pid: 0, test: self.name)
        a.settings.chargeLimit = limit
        a.settings.chargeControlEnabled = true
        accounts.append(a)
        return a
    }

    private func store(for a: Account, lockTimeout: TimeInterval = 3) -> ChargeRecordStore {
        ChargeRecordStore(directory: directory, uid: a.uid, pid: a.pid, isLive: { [unowned self] in live.contains($0) },
                          lockTimeout: lockTimeout)
    }

    /// A new process for the account: what `main.swift` does at the top and then in the middle of launch.
    @discardableResult
    private func launch(_ a: Account, shared: Bool = true, lockTimeout: TimeInterval = 3,
                        startDelay: TimeInterval = ChargeController.startDelay) -> ChargeController {
        nextPid += 1
        a.pid = nextPid
        live.insert(a.pid)
        a.records = ChargeRecords(settings: a.settings, store: shared ? store(for: a, lockTimeout: lockTimeout) : nil,
                                  log: { [weak a] in a?.lines.append($0) })
        let lifted = ChargeController.liftAtLaunch(settings: a.settings, records: a.records,
                                                   makeClient: { [macOS] in macOS }, helper: { a.helper },
                                                   log: { [weak a] in a?.lines.append($0) })
        let c = ChargeController(settings: a.settings, records: a.records, makeClient: { [macOS] in macOS },
                                 helper: a.helper, battery: { a.battery }, chargerSwitch: { nil },
                                 log: { [weak a] in a?.lines.append($0) }, workspace: a.center,
                                 limitInForce: ChargeLimitInForce(), startDelay: startDelay, liftedAtLaunch: lifted)
        a.controller = c
        return c
    }

    private func quit(_ a: Account) {
        a.controller?.shutdown()
        a.controller = nil
        live.remove(a.pid)
    }

    /// The process dies: nothing runs, nothing is put back, the setting and the record stay.
    private func crash(_ a: Account) {
        a.controller = nil
        live.remove(a.pid)
    }

    private func toBackground(_ a: Account) {
        a.center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
    }

    private func toForeground(_ a: Account) {
        a.center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
    }

    private var afterTheDelay: Date { Date().addingTimeInterval(ChargeController.startDelay + 1) }

    /// What the file says now, read by a store nobody holds with.
    private func file() -> ChargeRecordStore.Contents? {
        ChargeRecordStore(directory: directory, uid: 0, pid: 1, isLive: { _ in false }).peek()
    }

    private func holders() -> [ChargeHolder] {
        if case .record(let r)? = file() { return r.holders }
        return []
    }

    private func assertNoRecord(_ message: String = "the record outlived every holder",
                                file f: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(file(), ChargeRecordStore.Contents.none, message, file: f, line: line)
    }

    // ── The failure ─────────────────────────────────────────────────────────

    /// A holds 85 and goes to the background; B cold-starts. B does not take A's limit for macOS's own, and both quit
    /// in either order: macOS is back where it was and the record is gone.
    private func twoAccountsQuit(first: Int) throws {
        let a = try account("A", uid: 501, limit: 85)
        let b = try account("B", uid: 502, limit: 90)
        launch(a)
        XCTAssertEqual(macOS.state?.mclLimit, 85)
        toBackground(a)
        launch(b)
        if case .record(let r)? = file() {
            XCTAssertEqual(r.original, macOSOwn, "B took A's limit for macOS's own")
            XCTAssertEqual(Set(r.holders.map(\.uid)), [501, 502])
        } else {
            XCTFail("no record: \(String(describing: file()))")
        }
        XCTAssertTrue(b.lines.contains { $0.contains("already there stands") }, b.lines.joined(separator: "\n"))
        let order = first == 0 ? [a, b] : [b, a]
        quit(order[0])
        XCTAssertNotEqual(macOS.state, macOSOwn, "the first to quit put macOS back under the other's limit")
        XCTAssertEqual(holders().count, 1)
        quit(order[1])
        XCTAssertEqual(macOS.state, macOSOwn, "macOS was left at a limit with no Anode running")
        assertNoRecord()
        XCTAssertTrue(a.settings.chargeControlEnabled && b.settings.chargeControlEnabled)
    }

    func testTwoAccountsBothQuittingTheBackgroundOneFirstLeaveMacOSAsItWas() throws {
        try twoAccountsQuit(first: 0)
    }

    func testTwoAccountsBothQuittingTheOneOnScreenFirstLeaveMacOSAsItWas() throws {
        try twoAccountsQuit(first: 1)
    }

    /// DOCUMENTS A LIMITATION, it does not bless it: with per-account records (the shared file cannot be had, which is
    /// logged) the same two accounts cannot be told apart and the limit is left behind with no Anode running. This is
    /// why the record is shared, and why the fallback says so in the log.
    func testTheFallbackToPerAccountRecordsDocumentsThatTwoAccountsCannotBeToldApart() throws {
        let a = try account("A", uid: 501, limit: 85)
        let b = try account("B", uid: 502, limit: 90)
        launch(a, shared: false)
        toBackground(a)
        launch(b, shared: false)
        XCTAssertEqual(b.settings.chargeRestoreRecord.flatMap { ChargeController.decodeRecord($0) },
                       NativeChargeState(mclEnabled: true, mclLimit: 85, optimizedChargingEnabled: false),
                       "B recorded A's limit as macOS's own")
        quit(b)
        quit(a)
        XCTAssertNotEqual(macOS.state, macOSOwn, "per-account records are expected to leave A's limit behind")
    }

    // ── Switching off, quitting, crashing ───────────────────────────────────

    /// B switches off while A is running: B puts nothing back, the record stays with A as its holder, and A quitting
    /// (on screen or not) puts macOS back.
    func testSwitchingOffWhileAnotherAccountHoldsPutsNothingBack() throws {
        let a = try account("A", uid: 501, limit: 85)
        let b = try account("B", uid: 502, limit: 90)
        launch(a)
        launch(b)
        let held = macOS.state
        b.settings.chargeControlEnabled = false
        XCTAssertEqual(macOS.state, held, "B's switch-off changed A's limit")
        XCTAssertEqual(holders().map(\.uid), [501])
        XCTAssertTrue(b.lines.contains { $0.contains("another account's Anode is holding") },
                      b.lines.joined(separator: "\n"))
        toBackground(a)
        quit(a)
        XCTAssertEqual(macOS.state, macOSOwn, "A, the last holder, did not put macOS back because it was not on screen")
        assertNoRecord()
    }

    /// The same quitting on screen.
    func testTheLastHolderOnScreenPutsMacOSBack() throws {
        let a = try account("A", uid: 501, limit: 85)
        let b = try account("B", uid: 502, limit: 90)
        launch(a)
        launch(b)
        b.settings.chargeControlEnabled = false
        quit(a)
        XCTAssertEqual(macOS.state, macOSOwn)
        assertNoRecord()
    }

    /// A is not on screen and is the only holder: it puts macOS back. The old guard (nothing is put back while another
    /// account is on screen) is gone: whether it is on screen no longer matters, only whether it is the last holder.
    func testAnAccountQuittingInTheBackgroundThatIsTheLastHolderPutsMacOSBack() throws {
        let a = try account("A", uid: 501, limit: 85)
        launch(a)
        toBackground(a)
        quit(a)
        XCTAssertEqual(macOS.state, macOSOwn, "a quit in the background left the limit behind")
        assertNoRecord()
    }

    /// A crashes holding the limit: it is a stale holder. B, which adopted the record, quits as the last live one.
    func testAStaleHolderDoesNotKeepTheLimitFromTheOneThatQuitsLast() throws {
        let a = try account("A", uid: 501, limit: 85)
        let b = try account("B", uid: 502, limit: 90)
        launch(a)
        launch(b)
        crash(a)
        quit(b)
        XCTAssertEqual(macOS.state, macOSOwn)
        assertNoRecord()
    }

    /// A crashes while B still runs and relaunches: A takes the unclean route (the record lists it under another
    /// process) and waits, but it does not lift B's limit: B's Anode is alive and holds it. After the delay A joins B.
    func testAnAnodeThatCrashedAndRelaunchesDoesNotLiftTheLimitAnotherAccountHolds() throws {
        let a = try account("A", uid: 501, limit: 85)
        let b = try account("B", uid: 502, limit: 90)
        launch(a)
        launch(b)
        crash(a)
        let held = macOS.state
        let again = launch(a)
        XCTAssertTrue(again.isWaitingToStart, "A did not take the unclean route")
        XCTAssertEqual(macOS.state, held, "A lifted the limit B's Anode holds")
        XCTAssertEqual(holders().map(\.uid), [502], "A's stale entry stayed, or B's went")
        XCTAssertTrue(a.settings.chargeStartPending)
        XCTAssertTrue(a.lines.contains { $0.contains("another account's Anode is holding") },
                      a.lines.joined(separator: "\n"))

        again.resumeIfDue(now: afterTheDelay)
        XCTAssertFalse(again.isWaitingToStart)
        XCTAssertEqual(Set(holders().map(\.uid)), [501, 502])
        if case .record(let r)? = file() { XCTAssertEqual(r.original, macOSOwn) } else { XCTFail() }
        quit(b)
        XCTAssertNotEqual(macOS.state, macOSOwn, "B's quit put macOS back under A's limit")
        quit(a)
        XCTAssertEqual(macOS.state, macOSOwn)
        assertNoRecord()
    }

    /// The early lift obeys the same rule: a relaunch with nobody else holding lifts at once, as before.
    func testTheEarlyLiftWithNobodyElseHoldingPutsMacOSBack() throws {
        let a = try account("A", uid: 501, limit: 85)
        launch(a)
        crash(a)
        XCTAssertEqual(macOS.state?.mclLimit, 85)
        let again = launch(a)
        XCTAssertEqual(macOS.state, macOSOwn, "the lift did not put macOS back")
        XCTAssertTrue(again.isWaitingToStart)
        assertNoRecord()
        XCTAssertTrue(a.settings.chargeStartPending)
    }

    /// Switching on after a quit is a cold start, whoever else is running: the second account joins a record that
    /// stands, the first one that finds none writes macOS's own.
    func testASecondAccountSwitchedOnByHandJoinsTheRecordThatStands() throws {
        let a = try account("A", uid: 501, limit: 85)
        let b = try account("B", uid: 502, limit: 90)
        b.settings.chargeControlEnabled = false
        launch(a)
        launch(b)
        let held = macOS.state
        b.settings.chargeControlEnabled = true
        XCTAssertEqual(Set(holders().map(\.uid)), [501, 502])
        if case .record(let r)? = file() {
            XCTAssertEqual(r.original, macOSOwn, "A's limit was recorded as macOS's own")
        }
        XCTAssertNotNil(held)
    }

    // ── A record that cannot be reached for a moment ────────────────────────

    /// Another process holds the file's lock (it is in the middle of a restore) for longer than this one will wait.
    private func lockTheFile() throws -> Int32 {
        let fd = open(directory + "/" + ChargeRecordStore.fileName, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX), 0)
        return fd
    }

    /// A quit that cannot take the lock puts nothing back: the file is another Anode's to finish, the holders and the
    /// original in it are the truth, and macOS's defaults written in their place could land over another account's
    /// limit. Nothing is written to this account's own record either: the record stays the Mac's. The quit leaves
    /// this account a stale holder; the next launch of any account's Anode lifts.
    func testAQuitThatCannotReachTheSharedRecordPutsNothingBackAndWritesNoRecordOfItsOwn() throws {
        let a = try account("A", uid: 501, limit: 85)
        launch(a, lockTimeout: 0.2)
        let held = macOS.state
        let fd = try lockTheFile()
        let start = Date()
        quit(a)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3, "a locked record held the quit")
        flock(fd, LOCK_UN)
        close(fd)
        XCTAssertEqual(macOS.state, held, "macOS was written to without the record")
        XCTAssertNil(a.settings.chargeRestoreRecord, "a per-account record was written for a record that was only busy")
        if case .record(let r)? = file() {
            XCTAssertEqual(r.original, macOSOwn, "the record's original was lost")
        } else {
            XCTFail("the shared record was lost: \(String(describing: file()))")
        }
        XCTAssertTrue(a.lines.contains { $0.contains("could not be reached") }, a.lines.joined(separator: "\n"))
        // Nobody live holds it now: the next launch takes the unclean route and puts macOS back.
        launch(a)
        XCTAssertEqual(macOS.state, macOSOwn)
    }

    /// Switching on while the record is busy changes nothing and says so; it does not record what macOS says into this
    /// account's own preferences (that may be another account's limit), and the Mac's record is still the shared one
    /// once the lock is free: one busy moment does not turn the shared record off for the rest of the run.
    func testSwitchingOnWhileTheSharedRecordIsBusyChangesNothingAndDoesNotFallBackForGood() throws {
        let a = try account("A", uid: 501, limit: 85)
        let b = try account("B", uid: 502, limit: 90)
        launch(a)
        toBackground(a)
        let held = macOS.state
        b.settings.chargeControlEnabled = false
        launch(b, lockTimeout: 0.2)
        let fd = try lockTheFile()
        b.settings.chargeControlEnabled = true
        XCTAssertEqual(macOS.state, held, "macOS was changed without the record")
        XCTAssertNil(b.settings.chargeRestoreRecord, "A's limit was written down as B's own record")
        XCTAssertEqual(b.controller?.status, .unavailable(ChargeController.recordUnreachableText))
        XCTAssertTrue(b.lines.contains { $0.contains("could not be reached") }, b.lines.joined(separator: "\n"))
        flock(fd, LOCK_UN)
        close(fd)
        // Free again: off and on works, with the shared record, adopting A's.
        b.settings.chargeControlEnabled = false
        b.settings.chargeControlEnabled = true
        XCTAssertNil(b.settings.chargeRestoreRecord)
        XCTAssertEqual(Set(holders().map(\.uid)), [501, 502])
        if case .record(let r)? = file() { XCTAssertEqual(r.original, macOSOwn) } else { XCTFail() }
    }

    /// Switching off while the record is busy puts nothing back either, and does not guess.
    func testSwitchingOffWhileTheSharedRecordIsBusyPutsNothingBack() throws {
        let a = try account("A", uid: 501, limit: 85)
        launch(a, lockTimeout: 0.2)
        let held = macOS.state
        let fd = try lockTheFile()
        a.settings.chargeControlEnabled = false
        flock(fd, LOCK_UN)
        close(fd)
        XCTAssertEqual(macOS.state, held)
        XCTAssertNil(a.settings.chargeRestoreRecord)
    }

    // ── The uninstall restore ───────────────────────────────────────────────

    /// The headless restore leaves a limit another account's Anode holds, and says so (exit code 2).
    func testTheUninstallRestoreLeavesALimitAnotherAccountHolds() throws {
        let a = try account("A", uid: 501, limit: 85)
        let b = try account("B", uid: 502, limit: 90)
        launch(a)
        let held = macOS.state
        b.pid = 2000
        live.insert(2000)
        let records = ChargeRecords(settings: b.settings, store: store(for: b), log: { _ in })
        let outcome = ChargeController.restoreForUninstallOutcome(settings: b.settings, records: records,
                                                                  makeClient: { [macOS] in macOS }, helper: b.helper,
                                                                  log: { _ in })
        XCTAssertEqual(outcome, .heldByAnotherAccount)
        XCTAssertEqual(outcome.exitCode, 2)
        XCTAssertEqual(macOS.state, held, "the uninstall put macOS back under another account's limit")
        XCTAssertFalse(b.settings.chargeControlEnabled)
    }

    func testTheUninstallRestoreOfTheLastHolderPutsMacOSBack() throws {
        let a = try account("A", uid: 501, limit: 85)
        launch(a)
        crash(a)
        let records = ChargeRecords(settings: a.settings, store: store(for: a), log: { _ in })
        let outcome = ChargeController.restoreForUninstallOutcome(settings: a.settings, records: records,
                                                                  makeClient: { [macOS] in macOS }, helper: a.helper,
                                                                  log: { _ in })
        XCTAssertEqual(outcome, .cleared)
        XCTAssertEqual(outcome.exitCode, 0)
        XCTAssertEqual(macOS.state, macOSOwn)
        assertNoRecord()
    }

    // ── What the file may be ────────────────────────────────────────────────

    private func writeFile(_ text: String) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try text.write(toFile: directory + "/" + ChargeRecordStore.fileName, atomically: false, encoding: .utf8)
    }

    /// A file that is not a record, while Charge Control is on: taken for none, said once, nothing put back from it,
    /// and a record written anew from what macOS says.
    func testAFileThatIsNotARecordIsTakenForNoneAndSaidOnce() throws {
        try writeFile("{ this is not a record")
        let a = try account("A", uid: 501, limit: 85)
        launch(a)
        XCTAssertEqual(a.lines.filter { $0.contains("is not a record") }.count, 1, a.lines.joined(separator: "\n"))
        XCTAssertEqual(macOS.state?.mclLimit, 85)
        if case .record(let r)? = file() { XCTAssertEqual(r.original, macOSOwn) } else { XCTFail() }
        quit(a)
        XCTAssertEqual(macOS.state, macOSOwn)
    }

    /// Putting back with a file that is not a record (it went bad while Charge Control was on) puts nothing back.
    func testPuttingBackFromAFileThatWentBadPutsNothingBack() throws {
        let a = try account("A", uid: 501, limit: 85)
        launch(a)
        try writeFile("garbage")
        let held = macOS.state
        quit(a)
        XCTAssertEqual(macOS.state, held)
        XCTAssertTrue(a.lines.contains { $0.contains("is not a record") && $0.contains("nothing is put back") },
                      a.lines.joined(separator: "\n"))
    }

    /// A folder that cannot be written: the account falls back to its own record, with today's rules, and says one
    /// line that two accounts cannot be told apart on this Mac.
    func testAFolderThatCannotBeWrittenFallsBackToThisAccountsOwnRecord() throws {
        let blocker = (directory as NSString).deletingLastPathComponent + "/blocker"
        try "x".write(toFile: blocker, atomically: true, encoding: .utf8)
        let a = try account("A", uid: 501, limit: 85)
        nextPid += 1
        a.pid = nextPid
        live.insert(a.pid)
        let unusable = ChargeRecordStore(directory: blocker + "/Anode", uid: a.uid, pid: a.pid, isLive: { _ in true })
        a.records = ChargeRecords(settings: a.settings, store: unusable, log: { [weak a] in a?.lines.append($0) })
        let c = ChargeController(settings: a.settings, records: a.records, makeClient: { [macOS] in macOS },
                                 helper: a.helper, battery: { a.battery }, chargerSwitch: { nil },
                                 log: { [weak a] in a?.lines.append($0) }, workspace: a.center,
                                 limitInForce: ChargeLimitInForce())
        a.controller = c
        XCTAssertEqual(macOS.state?.mclLimit, 85)
        XCTAssertEqual(a.lines.filter { $0.contains("cannot be told apart") }.count, 1, a.lines.joined(separator: "\n"))
        XCTAssertNotNil(a.settings.chargeRestoreRecord, "the record was not kept in this account's preferences")
        quit(a)
        XCTAssertEqual(macOS.state, macOSOwn)
        XCTAssertNil(a.settings.chargeRestoreRecord)
    }

    /// Another account made the shared file a hard link to one of this account's private files. It is refused, said in
    /// one line, this account keeps its own record, and the private file is not made accessible or written.
    func testAHardLinkAtTheSharedFileFallsBackAndLeavesThePrivateFileAlone() throws {
        let secret = (directory as NSString).deletingLastPathComponent + "/private.txt"
        try "do not touch".write(toFile: secret, atomically: true, encoding: .utf8)
        XCTAssertEqual(chmod(secret, 0o600), 0)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        XCTAssertEqual(link(secret, directory + "/" + ChargeRecordStore.fileName), 0)
        let a = try account("A", uid: 501, limit: 85)
        launch(a)
        XCTAssertEqual(macOS.state?.mclLimit, 85)
        XCTAssertEqual(a.lines.filter { $0.contains("cannot be told apart") }.count, 1, a.lines.joined(separator: "\n"))
        XCTAssertTrue(a.lines.contains { $0.contains("more than one link") }, a.lines.joined(separator: "\n"))
        XCTAssertNotNil(a.settings.chargeRestoreRecord, "this account did not keep its own record")
        var info = stat()
        XCTAssertEqual(stat(secret, &info), 0)
        XCTAssertEqual(info.st_mode & 0o7777, 0o600)
        XCTAssertEqual(try String(contentsOfFile: secret, encoding: .utf8), "do not touch")
        quit(a)
        XCTAssertEqual(macOS.state, macOSOwn)
    }

    /// A per-account record an earlier build left is moved into the shared file once, with this account as a holder
    /// whose process is not known: the launch lifts the limit as for any run that did not quit, and nothing reads
    /// the per-account key afterwards.
    func testAnEarlierBuildsRecordIsMovedIntoTheSharedFileOnce() throws {
        let a = try account("A", uid: 501, limit: 85)
        a.settings.chargeRestoreRecord = ChargeController.encodeRecord(macOSOwn)
        macOS.state = NativeChargeState(mclEnabled: true, mclLimit: 85, optimizedChargingEnabled: false)   // held then
        let c = launch(a)
        XCTAssertEqual(macOS.state, macOSOwn, "the earlier build's limit was not lifted")
        XCTAssertNil(a.settings.chargeRestoreRecord, "the per-account record was kept after the move")
        XCTAssertTrue(c.isWaitingToStart)
        XCTAssertTrue(a.lines.contains { $0.contains("moved this account's record") }, a.lines.joined(separator: "\n"))
        assertNoRecord()
        // After the delay it switches on and records into the shared file; the per-account key stays empty.
        c.resumeIfDue(now: afterTheDelay)
        XCTAssertNil(a.settings.chargeRestoreRecord)
        if case .record(let r)? = file() { XCTAssertEqual(r.original, macOSOwn) } else { XCTFail() }
    }

    /// With a shared record there already, an earlier build's per-account record is dropped, not moved over it.
    func testAnEarlierBuildsRecordDoesNotReplaceTheSharedOne() throws {
        let a = try account("A", uid: 501, limit: 85)
        let b = try account("B", uid: 502, limit: 90)
        launch(a)
        b.settings.chargeControlEnabled = false
        b.settings.chargeRestoreRecord = ChargeController.encodeRecord(
            NativeChargeState(mclEnabled: true, mclLimit: 60, optimizedChargingEnabled: false))
        b.settings.chargeControlEnabled = true
        launch(b)
        if case .record(let r)? = file() {
            XCTAssertEqual(r.original, macOSOwn, "the stale per-account record replaced the shared one")
        } else {
            XCTFail()
        }
        XCTAssertNil(b.settings.chargeRestoreRecord)
    }

    // ── A launch that has nothing to do builds nothing ──────────────────────

    /// The normal launch with a shared file and nothing to lift: no client, no helper link, nothing written.
    func testALaunchWithNothingToLiftWritesNothing() throws {
        let a = try account("A", uid: 501, limit: 85)
        var clients = 0, helpers = 0
        let records = ChargeRecords(settings: a.settings, store: store(for: a))
        let lifted = ChargeController.liftAtLaunch(settings: a.settings, records: records, makeClient: {
            clients += 1
            return self.macOS
        }, helper: { helpers += 1; return a.helper }, log: { _ in })
        XCTAssertFalse(lifted)
        XCTAssertEqual(clients, 0)
        XCTAssertEqual(helpers, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory), "the early check created the shared folder")
    }

    /// Another account's live Anode holds a record; this account was not in it: that is not an unclean exit.
    func testAnotherAccountsRecordIsNotThisAccountsUncleanExit() throws {
        let a = try account("A", uid: 501, limit: 85)
        let b = try account("B", uid: 502, limit: 90)
        launch(a)
        nextPid += 1
        b.pid = nextPid
        live.insert(b.pid)
        let records = ChargeRecords(settings: b.settings, store: store(for: b))
        XCTAssertFalse(records.lastRunDidNotRelease())
        XCTAssertFalse(records.leftOverForThisAccount(), "a record another account's Anode holds is its to put back")
        XCTAssertTrue(records.hasRecord)
        XCTAssertTrue(records.heldByAnotherAccount)
    }
}
