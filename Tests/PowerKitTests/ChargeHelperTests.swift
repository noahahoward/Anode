import XCTest
@testable import PowerKit

// The helper's three charge commands — set macOS's charge limit, cut the charger
// to discharge, reconnect it — exercised against a fake. NOTHING here may build a
// `SystemChargeHardware`: that writes the real SMC and the real root preferences,
// and a cut outlives the process that made it. Reading its `static let`s is fine;
// that constructs nothing.
//
// EVERY CLASS HERE IS NAMED `ChargeHelperTests…`, so that
//
//     swift test --filter ChargeHelperTests
//
// runs every test in this file. A class named otherwise is silently skipped by
// that gate — which is how the dead man's switch test once went unrun by it.
// The sleep tests are `ChargeHelperSleepTests`, in their own file, and that
// gate does NOT run them: `swift test --filter ChargeHelper` runs both.

// ── Pure decisions, and the exact root surface ──────────────────────────────

final class ChargeHelperTestsWatch: XCTestCase {

    func testWatchRestoresAtTarget() {
        XCTAssertTrue(DischargeWatch.shouldRestore(target: 40, percent: 40, onAC: true))
        XCTAssertFalse(DischargeWatch.shouldRestore(target: 40, percent: 41, onAC: true))
        XCTAssertTrue(DischargeWatch.shouldRestore(target: 40, percent: nil, onAC: true),
                      "an unreadable battery must reconnect the charger, not keep draining")
        XCTAssertTrue(DischargeWatch.shouldRestore(target: 5, percent: 9, onAC: true),
                      "10% is a floor whatever the target says")
        XCTAssertTrue(DischargeWatch.shouldRestore(target: 40, percent: 70, onAC: false))
    }

    /// Unknown AC is not "unplugged". It is what the hardware reports when the
    /// battery cannot be read at all (see `ChargeAC.presence`), and treating it
    /// as unplugged would end a discharge on a read that failed.
    func testUnknownACDoesNotEndADischarge() {
        XCTAssertFalse(DischargeWatch.shouldRestore(target: 40, percent: 70, onAC: nil))
    }

    func testProtocolVersionIsTwo() {
        XCTAssertEqual(FanDaemon.protocolVersion, 2)
    }

    func testWireRoundTripOfChargeCommands() throws {
        let requests: [FanRequest] = [
            .command(.setChargeLimit(63)),
            .command(.discharge(toPercent: 40)),
            .command(.stopDischarge),
        ]
        for r in requests {
            var line = try FanWire.encode(r)
            XCTAssertEqual(line.last, 0x0A)
            line.removeLast()
            XCTAssertFalse(line.contains(0x0A))
            XCTAssertEqual(try FanWire.decode(FanRequest.self, from: line), r)
        }
    }

    /// The exact values root writes, and the exact bounds it enforces. Each one
    /// is a measured fact or a decision the plan names; a typo in any of them is
    /// a root process writing the wrong key, the wrong byte, or the wrong
    /// preference, and nothing else in the suite would notice.
    func testTheRootConstantsAreExactlyThePlans() {
        XCTAssertEqual(AdapterCutKey.key, "CHIE")
        XCTAssertEqual(AdapterCutKey.cut, 0x08)
        XCTAssertEqual(AdapterCutKey.connected, 0x00)
        XCTAssertEqual(SystemChargeHardware.limitDomain, "com.apple.smartcharging.topoffprotection")
        XCTAssertEqual(SystemChargeHardware.limitKey, "mclLimitValue")
        XCTAssertEqual(SystemChargeHardware.limitChanged, "com.apple.smartcharging.defaultschanged")
        XCTAssertEqual(FanHelperServer.chargeLimitRange, 20...100)
        XCTAssertEqual(FanHelperServer.dischargeTargetRange, 10...100)
        XCTAssertEqual(DischargeWatch.floor, 10)
    }
}

// ── The verified reconnect ──────────────────────────────────────────────────

/// `ChargeRelease` is the ONE reconnect: the server's dead man's switch, its
/// watch, its startup clear, `stopDischarge`, the failed-cut path and
/// `--uninstall` all call it. Tested here the way `FanRelease` is.
final class ChargeHelperTestsReconnect: XCTestCase {

    private let now = ChargeRelease.Timing.immediate

    func testACutChargerIsWrittenOnceAndReadBack() {
        let hw = FakeChargeHardware(cut: true)
        let r = ChargeRelease.reconnect(hw, timing: now)
        XCTAssertEqual(r, ChargeRelease.Result(.reconnected, writes: 1))
        XCTAssertTrue(r.ok)
        XCTAssertEqual(hw.cutWrites, [false])
        XCTAssertEqual(hw.isCut, false)
    }

    /// The everyday path — a helper starting, or `--uninstall`, on a charger
    /// nobody cut — writes nothing.
    func testAConnectedChargerIsNotWritten() {
        let hw = FakeChargeHardware(cut: false)
        let r = ChargeRelease.reconnect(hw, timing: now)
        XCTAssertEqual(r.outcome, .notCut)
        XCTAssertTrue(r.ok)
        XCTAssertTrue(hw.cutWrites.isEmpty)
    }

    /// A key that EXISTS but cannot be read is written — reconnecting cannot
    /// hurt — and the result says nobody knows, rather than claiming success.
    func testAnUnreadableKeyIsWrittenAndReportedUnconfirmed() {
        let hw = FakeChargeHardware(cut: true)
        hw.cutUnreadable = true
        let r = ChargeRelease.reconnect(hw, timing: now)
        XCTAssertEqual(r.outcome, .unconfirmed)
        XCTAssertFalse(r.ok)
        XCTAssertEqual(hw.cutWrites, [false, false, false])
        XCTAssertTrue(r.message.contains("may still be cut off"), r.message)
    }

    /// A Mac with no `CHIE` cannot have been cut by this helper. Nothing is
    /// written and nothing is called a failure — `--uninstall` on such a Mac
    /// used to print "FAILED to reconnect the charger".
    func testAMacWithNoKeyIsNotAFailure() {
        let hw = FakeChargeHardware()
        hw.keyExists = false
        let r = ChargeRelease.reconnect(hw, timing: now)
        XCTAssertEqual(r.outcome, .noKey)
        XCTAssertTrue(r.ok)
        XCTAssertTrue(hw.cutWrites.isEmpty)
    }

    func testARefusedReconnectIsTriedThreeTimesAndReportedStillCut() {
        let hw = FakeChargeHardware(cut: true)
        hw.refuseRestore = true
        let r = ChargeRelease.reconnect(hw, timing: now)
        XCTAssertEqual(r, ChargeRelease.Result(.stillCut, writes: 3))
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.message.contains("did NOT reconnect"), r.message)
    }

    /// THE CASE THE READ-BACK EXISTS FOR: the SMC says yes to 0x00 and the
    /// charger stays cut. Counting the write's return value would call this
    /// reconnected and stop watching a charger that is still cut.
    func testAReconnectTheSMCAcceptsAndDoesNotApplyIsNotDone() {
        let hw = FakeChargeHardware(cut: true)
        hw.ignoreRestore = true
        let r = ChargeRelease.reconnect(hw, timing: now)
        XCTAssertEqual(r.outcome, .stillCut)
        XCTAssertFalse(r.ok)
        XCTAssertEqual(hw.cutWrites, [false, false, false])
        XCTAssertEqual(hw.isCut, true)
    }

    func testTheThirdTryCounts() {
        let hw = FakeChargeHardware(cut: true)
        hw.restoreRefusalsLeft = 2
        XCTAssertEqual(ChargeRelease.reconnect(hw, timing: now),
                       ChargeRelease.Result(.reconnected, writes: 3))
        XCTAssertEqual(hw.isCut, false)
    }

    /// Straight after a cut attempt a read may still show the state from before
    /// it, so the reconnect is written whatever the key reads.
    func testAlwaysWriteWritesEvenWhenItReadsConnected() {
        let hw = FakeChargeHardware(cut: false)
        XCTAssertEqual(ChargeRelease.reconnect(hw, alwaysWrite: true, timing: now).outcome,
                       .reconnected)
        XCTAssertEqual(hw.cutWrites, [false])
    }

    /// The SMC is a microcontroller: a read in the same breath as the write can
    /// still see the old value. The read-back looks again rather than writing
    /// again.
    func testTheReadBackWaitsForTheWriteToShow() {
        let hw = LaggingCharge(cut: true, readsBeforeItShows: 2)
        let timing = ChargeRelease.Timing(tries: 3, readsPerTry: 4, readPause: 0, retryPause: 0)
        XCTAssertEqual(ChargeRelease.reconnect(hw, timing: timing),
                       ChargeRelease.Result(.reconnected, writes: 1))
        XCTAssertEqual(hw.writes, 1)
    }

    func testACutIsDoneOnlyWhenItReadsCut() {
        XCTAssertEqual(ChargeRelease.cut(FakeChargeHardware(), timing: now), .cut)

        let refusing = FakeChargeHardware()
        refusing.refuseCut = true
        XCTAssertEqual(ChargeRelease.cut(refusing, timing: now), .refused)

        // Accepted and not applied: the reply must not say "discharging".
        let ignoring = FakeChargeHardware()
        ignoring.ignoreCut = true
        XCTAssertEqual(ChargeRelease.cut(ignoring, timing: now), .notKept)
        XCTAssertFalse(ChargeRelease.CutOutcome.notKept.isCut)
        XCTAssertEqual(ignoring.isCut, false)
    }

    /// The other half of "judged by the read-back": a write that answers no
    /// and lands is a cut. The result byte of a good `CHIE` write is
    /// unmeasured; a Mac that answers it non-zero must still discharge.
    func testACutThatReadsCutIsACutWhateverTheWriteSaid() {
        let hw = FakeChargeHardware()
        hw.cutLandsButSaysNo = true
        let outcome = ChargeRelease.cut(hw, timing: now)
        XCTAssertEqual(outcome, .cutAlthoughRefused)
        XCTAssertTrue(outcome.isCut)
        XCTAssertTrue(ChargeRelease.CutOutcome.cut.isCut)
        XCTAssertFalse(ChargeRelease.CutOutcome.refused.isCut)
        XCTAssertEqual(hw.cutWrites, [true])
    }

    /// Holding a cut that read back, the key is known to exist: the reconnect
    /// is written whatever the first read says, and never called "no such key"
    /// — not when every read fails and the key-info question says no.
    func testAHeldCutIsAlwaysWrittenAndNeverCalledNoKey() {
        let gone = FakeChargeHardware(cut: true)
        gone.keyExists = false
        let r = ChargeRelease.reconnect(gone, holding: true, timing: now)
        XCTAssertEqual(r, ChargeRelease.Result(.unconfirmed, writes: 3))
        XCTAssertFalse(r.ok)
        XCTAssertEqual(gone.cutWrites, [false, false, false])

        // A read that says connected is not a reason to skip the write either.
        let reads = FakeChargeHardware(cut: false)
        XCTAssertEqual(ChargeRelease.reconnect(reads, holding: true, timing: now),
                       ChargeRelease.Result(.reconnected, writes: 1))
        XCTAssertEqual(reads.cutWrites, [false])

        // One failed read, and a key-info answer that failed the same way.
        let flaky = FakeChargeHardware(cut: true)
        flaky.failNextReads = 1
        flaky.existsAnswersNo = true
        XCTAssertEqual(ChargeRelease.reconnect(flaky, holding: true, timing: now),
                       ChargeRelease.Result(.reconnected, writes: 2))
        XCTAssertEqual(flaky.isCut, false)
    }

    /// ONLY 0x08 IS ANODE'S CUT. A reconnect that holds nothing — the startup
    /// clear, a stop with no discharge held, `--uninstall` — clears the key
    /// when it reads exactly that, and leaves any other non-zero value alone:
    /// nobody here has measured what it means, and it used to be written over
    /// with 0x00 as though Anode had put it there.
    func testAValueAnodeNeverWritesIsLeftAloneWhenNothingIsHeld() {
        for value: UInt8 in [0x01, 0x04, 0x09, 0x0C, 0x80, 0xFF] {
            let hw = FakeChargeHardware()
            hw.unknownValue = value
            let r = ChargeRelease.reconnect(hw, timing: now)
            XCTAssertEqual(r, ChargeRelease.Result(.unrecognised(value), writes: 0))
            XCTAssertTrue(r.ok, r.message)
            XCTAssertTrue(hw.cutWrites.isEmpty, "\(value) was written over")
            XCTAssertTrue(r.message.contains(String(format: "0x%02X", value)), r.message)
            XCTAssertEqual(hw.unknownValue, value)
        }
        // And 0x08 itself still is cleared.
        let ours = FakeChargeHardware(cut: true)
        XCTAssertEqual(ChargeRelease.reconnect(ours, timing: now),
                       ChargeRelease.Result(.reconnected, writes: 1))
    }

    /// Holding a cut, owing a reconnect, or undoing a cut that did not read
    /// back, the rule above does not apply: the reconnect is written whatever
    /// the key reads, and judged by the read-back.
    func testAHeldOrUndoneCutIsWrittenOverAnyValue() {
        let held = FakeChargeHardware()
        held.unknownValue = 0x0C
        XCTAssertEqual(ChargeRelease.reconnect(held, holding: true, timing: now),
                       ChargeRelease.Result(.reconnected, writes: 1))
        XCTAssertEqual(held.cutWrites, [false])

        let undo = FakeChargeHardware()
        undo.unknownValue = 0x0C
        XCTAssertEqual(ChargeRelease.reconnect(undo, alwaysWrite: true, timing: now),
                       ChargeRelease.Result(.reconnected, writes: 1))
        XCTAssertEqual(undo.cutWrites, [false])
    }

    /// Not holding — the undo of a cut that did not read back — a Mac the SMC
    /// says has no `CHIE` is still `.noKey` after the writes, so a discharge
    /// asked of such a Mac does not leave a helper owing a reconnect for ever.
    func testAnUndoOnAMacWithNoKeyIsNoKey() {
        let hw = FakeChargeHardware()
        hw.keyExists = false
        let r = ChargeRelease.reconnect(hw, alwaysWrite: true, timing: now)
        XCTAssertEqual(r, ChargeRelease.Result(.noKey, writes: 3))
        XCTAssertTrue(r.ok)
    }

    /// "No such key" is the SMC's own answer and nothing else. MEASURED
    /// read-only on this Mac: a key that is not there answers IOKit 0, result
    /// 0x84, size 0. Every other failure — an IOKit error, an in-band timeout
    /// (0xB6), a short buffer — says nothing, and the key might exist. The old
    /// `exists` answered "no such key" for all of them, and the charger
    /// believed it.
    func testOnlyTheSMCsOwnNoSuchKeyMeansAbsent() {
        func info(result: UInt8, size: UInt32) -> [UInt8] {
            var b = [UInt8](repeating: 0, count: 80)
            b[40] = result
            b[28] = UInt8(size & 0xFF)
            b[29] = UInt8((size >> 8) & 0xFF)
            b[30] = UInt8((size >> 16) & 0xFF)
            b[31] = UInt8((size >> 24) & 0xFF)
            return b
        }
        XCTAssertEqual(SMC.noSuchKey, 0x84)
        XCTAssertTrue(SMC.saysNoSuchKey(rc: kIOReturnSuccess, output: info(result: 0x84, size: 0)))

        XCTAssertFalse(SMC.saysNoSuchKey(rc: kIOReturnSuccess, output: info(result: 0x84, size: 1)))
        XCTAssertFalse(SMC.saysNoSuchKey(rc: kIOReturnSuccess, output: info(result: 0, size: 0)),
                       "size 0 with no 'no such key' is not an answer")
        XCTAssertFalse(SMC.saysNoSuchKey(rc: kIOReturnSuccess, output: info(result: 0xB6, size: 0)),
                       "an SMC timeout was taken for 'no such key'")
        XCTAssertFalse(SMC.saysNoSuchKey(rc: kIOReturnSuccess, output: info(result: 0, size: 1)))
        XCTAssertFalse(SMC.saysNoSuchKey(rc: kIOReturnNotPrivileged, output: info(result: 0x84, size: 0)))
        XCTAssertFalse(SMC.saysNoSuchKey(rc: kIOReturnTimeout, output: info(result: 0, size: 0)),
                       "an IOKit error was taken for 'no such key'")
        XCTAssertFalse(SMC.saysNoSuchKey(rc: kIOReturnSuccess, output: [0x84]))
    }

    /// The SMC's own result byte, not only IOKit's return code. MEASURED
    /// read-only on this Mac: a key that does not exist answers IOKit 0 with
    /// result 132 (0x84) and a zeroed buffer, which `readByte` used to hand
    /// back as 0x00 — for `CHIE`, "connected".
    func testTheSMCsOwnResultByteIsChecked() {
        var ok = [UInt8](repeating: 0, count: 80)
        XCTAssertTrue(SMC.succeeded(rc: kIOReturnSuccess, output: ok))
        ok[40] = 132
        XCTAssertFalse(SMC.succeeded(rc: kIOReturnSuccess, output: ok),
                       "an SMC-level 'no such key' passed as success")
        ok[40] = 1
        XCTAssertFalse(SMC.succeeded(rc: kIOReturnSuccess, output: ok))
        XCTAssertFalse(SMC.succeeded(rc: kIOReturnNotPrivileged,
                                     output: [UInt8](repeating: 0, count: 80)))
        XCTAssertFalse(SMC.succeeded(rc: kIOReturnSuccess, output: [0, 0]))
    }
}

/// A charger whose reads lag its writes by a few reads.
private final class LaggingCharge: ChargeHardware {
    private var cut: Bool
    private var pending: Bool?
    private var readsLeft = 0
    private let lag: Int
    private(set) var writes = 0

    init(cut: Bool, readsBeforeItShows lag: Int) {
        self.cut = cut
        self.lag = lag
    }

    func adapterCut() -> Bool? {
        if let pending {
            if readsLeft == 0 { cut = pending; self.pending = nil } else { readsLeft -= 1 }
        }
        return cut
    }
    func setAdapterCut(_ on: Bool) -> Bool {
        writes += 1
        pending = on
        readsLeft = lag
        return true
    }
    func batteryPercent() -> Int? { 50 }
    func onAC() -> Bool? { nil }
    func writeChargeLimit(_ percent: Int) -> Bool { true }
}

// ── A client's bytes, before they are a request ─────────────────────────────

final class ChargeHelperTestsLines: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    func testAWholeLineIsServedAndTheRestKept() {
        var lines = RequestLines()
        lines.append(Array("{a}\n{b".utf8), at: t0)
        XCTAssertTrue(lines.hasLine)
        XCTAssertNil(lines.unfinishedSince, "a whole line is waiting; nothing is late")
        XCTAssertEqual(lines.next(at: t0), Data("{a}".utf8))
        XCTAssertNil(lines.next(at: t0))
        XCTAssertEqual(lines.unfinishedSince, t0)
    }

    /// A client that drips a byte at a time does not keep extending its own
    /// deadline. The old read restarted its 5 s timeout on every byte, so one
    /// byte every few seconds held the helper's only thread for hours.
    func testTheDeadlineCountsFromTheFirstByte() {
        var lines = RequestLines()
        lines.append([0x7B], at: t0)
        lines.append([0x22], at: t0 + 3)
        lines.append([0x22], at: t0 + 4.5)
        XCTAssertFalse(lines.stalled(at: t0 + 4.9, after: 5))
        XCTAssertTrue(lines.stalled(at: t0 + 5, after: 5))
    }

    func testAFinishedLineStopsTheClock() {
        var lines = RequestLines()
        lines.append(Array("{\"hel".utf8), at: t0)
        lines.append(Array("lo\":{}}\n".utf8), at: t0 + 1)
        XCTAssertNil(lines.unfinishedSince)
        XCTAssertFalse(lines.stalled(at: t0 + 100, after: 5))
    }

    func testALineLongerThanARequestCanBeIsTooLong() {
        var lines = RequestLines()
        lines.append([UInt8](repeating: 0x20, count: FanWire.maxLineBytes), at: t0)
        XCTAssertFalse(lines.tooLong)
        lines.append([0x20], at: t0)
        XCTAssertTrue(lines.tooLong)
        lines.append([0x0A], at: t0)
        XCTAssertFalse(lines.tooLong, "a finished line is served, not refused for length here")
    }

    func testResetForgetsEverything() {
        var lines = RequestLines()
        lines.append(Array("{\"x".utf8), at: t0)
        lines.reset()
        XCTAssertTrue(lines.pending.isEmpty)
        XCTAssertNil(lines.unfinishedSince)
    }
}

// ── The helper's process: its log sink and its signals ─────────────────────

final class ChargeHelperTestsProcess: XCTestCase {

    private var openFDs: [Int32] = []

    override func tearDown() {
        for fd in openFDs { close(fd) }
        openFDs = []
        super.tearDown()
    }

    private func makePipe() -> (read: Int32, write: Int32) {
        var p: [Int32] = [-1, -1]
        XCTAssertEqual(pipe(&p), 0)
        openFDs += p
        return (p[0], p[1])
    }

    func testTheLogSinkWritesALine() {
        let p = makePipe()
        XCTAssertTrue(HelperLog.line("anode-helper: hello", to: p.write))
        var buf = [UInt8](repeating: 0, count: 64)
        let n = read(p.read, &buf, buf.count)
        XCTAssertEqual(String(decoding: buf[0..<max(n, 0)], as: UTF8.self), "anode-helper: hello\n")
    }

    /// `sudo AnodeHelper 2>&1 | tee log`, then ⌃C kills tee: the next line goes
    /// to a pipe nobody reads. That used to be SIGPIPE — the process dead, the
    /// charger cut. If this test process is still here to fail, it passed the
    /// part that matters.
    func testTheLogSinkSurvivesAReaderThatIsGone() {
        let p = makePipe()
        close(p.read)
        openFDs.removeAll { $0 == p.read }
        XCTAssertFalse(HelperLog.line("anode-helper: client gone", to: p.write))
    }

    /// A descriptor that is no longer there — the stand-in for a Terminal
    /// window that closed (EIO from a hung-up tty). The old sink raised an
    /// Objective-C exception here and the helper aborted.
    func testTheLogSinkSurvivesADescriptorThatIsGone() {
        let p = makePipe()
        close(p.write)
        openFDs.removeAll { $0 == p.write }
        XCTAssertFalse(HelperLog.line("anode-helper: stopped", to: p.write))
    }

    /// stderr that nobody drains (`| less`, or ⌃S in the window) must not hold
    /// the helper's only thread — the one that watches the discharge floor.
    func testTheLogSinkDoesNotWaitOnAFullPipe() {
        let p = makePipe()
        _ = fcntl(p.write, F_SETNOSIGPIPE, 1)
        let flags = fcntl(p.write, F_GETFL)
        _ = fcntl(p.write, F_SETFL, flags | O_NONBLOCK)
        var block = [UInt8](repeating: 0x2E, count: 4096)
        while write(p.write, &block, block.count) > 0 {}
        _ = fcntl(p.write, F_SETFL, flags)          // blocking again, like stderr

        let done = expectation(description: "the sink returned")
        let result = ResultBox()
        let fd = p.write
        Thread.detachNewThread {
            result.set(HelperLog.line("anode-helper: discharge to 40% ended", to: fd))
            done.fulfill()
        }
        let waited = XCTWaiter.wait(for: [done], timeout: 1)
        if waited != .completed {
            // Unstick it before failing, so the thread does not outlive the test.
            close(p.read)
            openFDs.removeAll { $0 == p.read }
        }
        XCTAssertEqual(waited, .completed, "the log sink blocked on a full pipe")
        XCTAssertEqual(result.value, false)
    }

    /// ⌃\ and a stray `kill -USR1` used to end the session helper by their
    /// default action, charger cut; ⌃Z suspended it, alive to every check and
    /// enforcing nothing. Every one of them now either takes the ⌃C path or is
    /// ignored.
    func testSignalsThatWouldEndOrSuspendTheHelperAreHandled() {
        XCTAssertEqual(Set(HelperSignals.stop),
                       [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGUSR1, SIGUSR2, SIGALRM, SIGXCPU, SIGXFSZ])
        XCTAssertEqual(Set(HelperSignals.ignored), [SIGPIPE, SIGTSTP, SIGTTIN, SIGTTOU])

        // Installed for real in this process, then put back exactly as found.
        let all = HelperSignals.stop + HelperSignals.ignored
        var saved: [Int32: sigaction] = [:]
        for sig in all {
            var old = sigaction()
            sigaction(sig, nil, &old)
            saved[sig] = old
        }
        let lock = NSLock()
        var stops = 0
        HelperSignals.ignoreTheOnesThatMustNotLand()
        let sources = HelperSignals.routeToStop { lock.lock(); stops += 1; lock.unlock() }
        defer {
            sources.forEach { $0.cancel() }
            for (sig, old) in saved {
                var o = old
                sigaction(sig, &o, nil)
            }
        }

        for sig in all {
            XCTAssertTrue(isIgnored(sig), "signal \(sig) still has its default action")
        }
        // Only sent once it is known to be ignored, so a regression fails here
        // instead of killing or stopping the test runner. `kill`, not `raise`:
        // ⌃\ and `kill` are process-directed, and a thread-directed `raise` of
        // an ignored signal never reaches a dispatch source (measured).
        guard isIgnored(SIGQUIT), isIgnored(SIGUSR1) else { return }
        kill(getpid(), SIGQUIT)
        kill(getpid(), SIGUSR1)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            lock.lock(); let n = stops; lock.unlock()
            if n >= 2 { break }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        lock.lock(); let n = stops; lock.unlock()
        XCTAssertEqual(n, 2, "SIGQUIT and SIGUSR1 must each reach stop()")
    }

    private func isIgnored(_ sig: Int32) -> Bool {
        var now = sigaction()
        guard sigaction(sig, nil, &now) == 0 else { return false }
        return unsafeBitCast(now.__sigaction_u.__sa_handler, to: Int.self)
            == unsafeBitCast(SIG_IGN, to: Int.self)
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Bool?
        func set(_ v: Bool) { lock.lock(); stored = v; lock.unlock() }
        var value: Bool? { lock.lock(); defer { lock.unlock() }; return stored }
    }
}

// ── What a person reads before authorising ─────────────────────────────────

final class ChargeHelperTestsDisclosure: XCTestCase {

    func testTheVocabularyIsTheHelpersWholeSurface() {
        XCTAssertEqual(HelperVocabulary.commands, [
            "set fan N to R rpm",
            "release the fans",
            "set the macOS charge limit (20–100%)",
            "cut the charger to discharge down to a percentage",
            "reconnect it",
        ])
        XCTAssertEqual(HelperVocabulary.sentence,
                       "set fan N to R rpm, release the fans, set the macOS charge limit "
                     + "(20–100%), cut the charger to discharge down to a percentage, "
                     + "and reconnect it")
    }

    /// Both sheets that come before a root helper is authorised name all five
    /// commands. They described a fan-only helper after the charger commands
    /// were added, so a person agreed to one thing and installed another.
    func testEverySheetBeforeAuthorisingNamesTheWholeVocabulary() {
        let sheets = ["install sheet": FanElevation.installDisclosure,
                      "session sheet": FanElevation.sessionDisclosure]
        for (name, text) in sheets {
            for command in HelperVocabulary.commands {
                XCTAssertTrue(text.contains(command), "the \(name) does not say \"\(command)\"")
            }
            XCTAssertTrue(text.contains("never goes below 10%"), "the \(name) omits the floor")
            XCTAssertTrue(text.contains("charger is reconnected") || text.contains("reconnects the charger"),
                          "the \(name) does not say how the charger comes back")
        }
    }

    func testTheSystemPromptsNameTheCharger() {
        XCTAssertTrue(FanElevation.installPrompt.contains("charge limit"))
        XCTAssertTrue(FanElevation.installPrompt.contains("cuts or reconnects the charger"))
        XCTAssertTrue(FanElevation.uninstallPrompt.contains("reconnect the charger"))
        XCTAssertTrue(FanElevation.uninstallDone.contains("the charger is reconnected"))
    }
}

// ── The server, driven directly ─────────────────────────────────────────────

final class ChargeHelperTests: XCTestCase {

    private func makeServer(_ charge: FakeChargeHardware,
                            fans: FakeFans = FakeFans([:]),
                            log: @escaping (String) -> Void = { _ in }) -> FanHelperServer {
        let server = FanHelperServer(
            hardware: fans,
            configuration: .init(socketPath: NSTemporaryDirectory() + "bs-unused.sock",
                                 ownerUID: getuid(),
                                 pin: .signingIdentifier(FanDaemon.clientSigningIdentifier)),
            log: log,
            charge: charge)
        server.chargeTiming = .immediate
        return server
    }

    func testSetChargeLimitWritesOnceAndRejectsOutOfRange() {
        let hw = FakeChargeHardware()
        let server = makeServer(hw)

        XCTAssertTrue(server.handle(.command(.setChargeLimit(63))).ok)
        XCTAssertEqual(hw.limitWrites, [63])

        for bad in [19, 101, 0, -5] {
            let reply = server.handle(.command(.setChargeLimit(bad)))
            XCTAssertFalse(reply.ok, "\(bad) was accepted")
            XCTAssertFalse(reply.message.isEmpty)
        }
        XCTAssertEqual(hw.limitWrites, [63], "an out-of-range limit reached the preferences")
        XCTAssertTrue(hw.cutWrites.isEmpty, "a limit write touched the charger")
    }

    /// Both ends of both ranges, through the server: an off-by-one at either
    /// end is a limit the plan promises and root refuses, or one it forbids
    /// and root writes.
    func testTheEndsOfBothRangesAreAccepted() {
        let hw = FakeChargeHardware(percent: 77)
        let server = makeServer(hw)
        XCTAssertTrue(server.handle(.command(.setChargeLimit(20))).ok)
        XCTAssertTrue(server.handle(.command(.setChargeLimit(100))).ok)
        XCTAssertEqual(hw.limitWrites, [20, 100])

        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 10))).ok,
                      "the lowest target the plan allows was refused")
        XCTAssertEqual(server.dischargeTarget, 10)
        XCTAssertTrue(server.handle(.command(.stopDischarge)).ok)

        // 100 is inside the range; it is refused only because the battery is
        // always at or below it — and the reply must say THAT, not "out of range".
        let top = server.handle(.command(.discharge(toPercent: 100)))
        XCTAssertFalse(top.ok)
        XCTAssertTrue(top.message.contains("already at or below 100%"), top.message)
        for outside in [9, 101] {
            let reply = server.handle(.command(.discharge(toPercent: outside)))
            XCTAssertTrue(reply.message.contains("must be 10–100%"), "\(outside): \(reply.message)")
        }
    }

    func testSetChargeLimitReportsAFailedWrite() {
        let hw = FakeChargeHardware()
        hw.refuseLimitWrites = true
        XCTAssertFalse(makeServer(hw).handle(.command(.setChargeLimit(80))).ok)
    }

    func testDischargeCutsAndRecordsTarget() {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        let server = makeServer(hw)

        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)
        XCTAssertEqual(hw.cutWrites, [true])
        XCTAssertEqual(hw.isCut, true)
        XCTAssertEqual(server.dischargeTarget, 40)
    }

    func testDischargeRefusedWhenAlreadyAtTargetOrUnplugged() {
        let atTarget = FakeChargeHardware(percent: 40, onAC: true)
        let s1 = makeServer(atTarget)
        XCTAssertFalse(s1.handle(.command(.discharge(toPercent: 40))).ok)
        XCTAssertTrue(atTarget.cutWrites.isEmpty)
        XCTAssertNil(s1.dischargeTarget)

        let unplugged = FakeChargeHardware(percent: 77, onAC: false)
        let s2 = makeServer(unplugged)
        XCTAssertFalse(s2.handle(.command(.discharge(toPercent: 40))).ok)
        XCTAssertTrue(unplugged.cutWrites.isEmpty)
        XCTAssertNil(s2.dischargeTarget)
    }

    func testDischargeRefusesATargetOutOfRange() {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        let server = makeServer(hw)
        for bad in [9, 101, 0, -1] {
            XCTAssertFalse(server.handle(.command(.discharge(toPercent: bad))).ok, "\(bad)")
        }
        XCTAssertTrue(hw.cutWrites.isEmpty)
        XCTAssertNil(server.dischargeTarget)
    }

    /// A refused cut takes nothing — but the reconnect is still sent, because a
    /// write the SMC "refused" is not proof that it did nothing.
    func testAFailedCutIsReportedAndHoldsNothing() {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        hw.refuseCut = true
        let server = makeServer(hw)
        XCTAssertFalse(server.handle(.command(.discharge(toPercent: 40))).ok)
        XCTAssertNil(server.dischargeTarget)
        XCTAssertEqual(hw.cutWrites.last, false, "a failed cut was not followed by a reconnect")
    }

    /// The SMC accepts the cut and the charger does not read cut. The reply
    /// used to say "discharging to 40%" with nothing cut and a 10 s watch that
    /// never ended; now it is a failed cut, undone with a reconnect.
    func testACutTheSMCAcceptsAndDoesNotApplyIsRefusedAndUndone() {
        let hw = FakeChargeHardware(percent: 77)
        hw.ignoreCut = true
        let server = makeServer(hw)
        let reply = server.handle(.command(.discharge(toPercent: 40)))
        XCTAssertFalse(reply.ok, reply.message)
        XCTAssertNil(server.dischargeTarget)
        XCTAssertEqual(hw.cutWrites, [true, false])
        XCTAssertTrue(server.isIdle)
    }

    func testStopDischargeRestores() {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        let server = makeServer(hw)
        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)

        XCTAssertTrue(server.handle(.command(.stopDischarge)).ok)
        XCTAssertEqual(hw.cutWrites, [true, false])
        XCTAssertEqual(hw.isCut, false)
        XCTAssertNil(server.dischargeTarget)
    }

    /// The SMC accepts the reconnect and the charger stays cut. The discharge is
    /// NOT over: the target is kept, the helper stays up, the reply says so, and
    /// the watch keeps writing until the key reads connected.
    func testAReconnectTheSMCAcceptsAndDoesNotApplyIsKeptAndRetried() {
        let hw = FakeChargeHardware(percent: 77)
        var lines: [String] = []
        let server = makeServer(hw, log: { lines.append($0) })
        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)

        hw.ignoreRestore = true
        let reply = server.handle(.command(.stopDischarge))
        XCTAssertFalse(reply.ok)
        XCTAssertTrue(reply.message.contains("did NOT reconnect"), reply.message)
        XCTAssertEqual(server.dischargeTarget, 40)
        XCTAssertTrue(server.reconnectOwed)
        XCTAssertFalse(server.isIdle)

        server.watchDischarge()
        XCTAssertEqual(hw.isCut, true)
        XCTAssertTrue(lines.last?.contains("retrying") ?? false, "\(lines)")

        hw.ignoreRestore = false
        server.watchDischarge()
        XCTAssertEqual(hw.isCut, false)
        XCTAssertNil(server.dischargeTarget)
        XCTAssertTrue(server.isIdle)
    }

    /// Asked to reconnect, it reconnects — even a cut this helper does not
    /// remember making.
    func testStopDischargeClearsACutItDidNotMake() {
        let hw = FakeChargeHardware(percent: 77, onAC: true, cut: true)
        let server = makeServer(hw)
        XCTAssertTrue(server.handle(.command(.stopDischarge)).ok)
        XCTAssertEqual(hw.isCut, false)
    }

    func testStopDischargeWithNothingCutWritesNothing() {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        XCTAssertTrue(makeServer(hw).handle(.command(.stopDischarge)).ok)
        XCTAssertTrue(hw.cutWrites.isEmpty)
    }

    func testReleaseAllRestoresAdapterCut() {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        let server = makeServer(hw)
        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)

        // No fan is held, which is the case the fan release used to return early on.
        XCTAssertTrue(server.handle(.command(.releaseAll)).ok)
        XCTAssertEqual(hw.isCut, false)
        XCTAssertNil(server.dischargeTarget)
    }

    private func oneFan() -> FakeFans {
        let fans = FakeFans([0: .init(minRPM: 2317, maxRPM: 7826)])
        fans.seedTarget(0, 0)
        fans.seedMode(0, SMCFanMode.automatic)
        return fans
    }

    /// A fan AND a discharge held at once: `releaseAll` hands back both, fans
    /// as they were found and the charger reconnected.
    func testReleaseAllHandsBackAHeldFanAndTheCharger() {
        let hw = FakeChargeHardware(percent: 77)
        let fans = oneFan()
        let server = makeServer(hw, fans: fans)
        XCTAssertTrue(server.handle(.command(.setTarget(FanTarget(index: 0, rpm: 5000)))).ok)
        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)

        let reply = server.handle(.command(.releaseAll))
        XCTAssertTrue(reply.ok, reply.message)
        XCTAssertTrue(reply.message.contains("put back"), reply.message)
        XCTAssertTrue(reply.message.contains("charger reconnected"), reply.message)
        XCTAssertEqual(fans.targetWrites.map(\.rpm), [5000, 0])
        XCTAssertEqual(fans.modeWrites.last?.mode, SMCFanMode.automatic)
        XCTAssertFalse(server.hasWrittenATarget)
        XCTAssertEqual(hw.isCut, false)
        XCTAssertNil(server.dischargeTarget)
    }

    /// A charger that will not reconnect must not cost the fans their release:
    /// the reply is not ok, the fans are back on automatic anyway, and the
    /// discharge target is kept so the watch keeps trying.
    func testAFailedReconnectStillReleasesTheFans() {
        let hw = FakeChargeHardware(percent: 77)
        let fans = oneFan()
        let server = makeServer(hw, fans: fans)
        XCTAssertTrue(server.handle(.command(.setTarget(FanTarget(index: 0, rpm: 5000)))).ok)
        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)

        hw.refuseRestore = true
        let reply = server.handle(.command(.releaseAll))
        XCTAssertFalse(reply.ok, reply.message)
        XCTAssertEqual(fans.targetWrites.map(\.rpm), [5000, 0], "the fans were skipped")
        XCTAssertFalse(server.hasWrittenATarget)
        XCTAssertEqual(server.dischargeTarget, 40)
        XCTAssertEqual(hw.isCut, true)
    }

    /// A reconnect that fails keeps the target, so the helper stays up and tries
    /// again on its next check rather than forgetting a cut it still holds.
    func testAFailedReconnectIsKeptAndRetried() {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        let server = makeServer(hw)
        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)

        hw.refuseRestore = true
        XCTAssertFalse(server.handle(.command(.stopDischarge)).ok)
        XCTAssertNotNil(server.dischargeTarget)
        XCTAssertFalse(server.isIdle)

        hw.refuseRestore = false
        server.watchDischarge()
        XCTAssertEqual(hw.isCut, false)
        XCTAssertNil(server.dischargeTarget)
    }

    func testTheWatchReconnectsAtTheTarget() {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        let server = makeServer(hw)
        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)

        hw.percent = 41
        server.watchDischarge()
        XCTAssertEqual(hw.isCut, true, "reconnected above the target")
        XCTAssertEqual(server.dischargeTarget, 40)

        hw.percent = 40
        server.watchDischarge()
        XCTAssertEqual(hw.isCut, false)
        XCTAssertNil(server.dischargeTarget)
    }

    func testTheWatchReconnectsWhenTheBatteryCannotBeRead() {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        let server = makeServer(hw)
        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)
        hw.percent = nil
        server.watchDischarge()
        XCTAssertEqual(hw.isCut, false)
    }

    /// The fake answers as the hardware does: while the charger is cut, the
    /// cable being in is still reported as in (`ChargeAC.presence` reads the
    /// charger's own details, not the flag the cut clears). A watch that ended
    /// a discharge on the cut itself would end every real one on its first pass.
    func testCableStillInKeepsDischarging() {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        let server = makeServer(hw)
        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)
        XCTAssertEqual(hw.onAC(), true, "the cable is in, and the hardware says so while cut")
        for _ in 0..<3 { server.watchDischarge() }
        XCTAssertEqual(hw.isCut, true)
        XCTAssertEqual(server.dischargeTarget, 40)
    }

    /// The cable pulled in the middle of a discharge: the next watch pass
    /// reconnects the charger and clears the target. Before the helper could
    /// tell a pulled cable from its own cut it answered unknown, and kept the
    /// charger cut.
    func testPulledCableEndsTheDischarge() {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        let server = makeServer(hw)
        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)
        server.watchDischarge()
        XCTAssertEqual(hw.isCut, true, "still cut with the cable in")

        hw.cable = false
        XCTAssertEqual(hw.onAC(), false)
        server.watchDischarge()
        XCTAssertEqual(hw.isCut, false)
        XCTAssertNil(server.dischargeTarget)
    }

    /// A cable that cannot be told either way is not a pulled one.
    func testAnUnreadableCableKeepsADischargeRunning() {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        let server = makeServer(hw)
        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)
        hw.cable = nil
        for _ in 0..<3 { server.watchDischarge() }
        XCTAssertEqual(hw.isCut, true)
        XCTAssertEqual(server.dischargeTarget, 40)
    }

    func testStartupClearsOrphanedCut() {
        let hw = FakeChargeHardware(percent: 77, onAC: true, cut: true)
        var lines: [String] = []
        let server = makeServer(hw, log: { lines.append($0) })
        server.clearOrphanedAdapterCut()
        XCTAssertEqual(hw.isCut, false)
        XCTAssertEqual(hw.cutWrites, [false])
        XCTAssertTrue(lines.contains("cleared an adapter cut nobody owned"), "\(lines)")
    }

    func testStartupLeavesAConnectedChargerAlone() {
        let hw = FakeChargeHardware(percent: 77, onAC: true, cut: false)
        var lines: [String] = []
        makeServer(hw, log: { lines.append($0) }).clearOrphanedAdapterCut()
        XCTAssertTrue(hw.cutWrites.isEmpty, "the default path must write nothing")
        XCTAssertTrue(lines.isEmpty, "the default path must say nothing")
    }

    func testStartupOnAMacWithNoKeyWritesNothing() {
        let hw = FakeChargeHardware()
        hw.keyExists = false
        var lines: [String] = []
        makeServer(hw, log: { lines.append($0) }).clearOrphanedAdapterCut()
        XCTAssertTrue(hw.cutWrites.isEmpty)
        XCTAssertTrue(lines.isEmpty, "\(lines)")
    }

    /// Startup finds `CHIE` holding a value Anode never writes: nothing is
    /// written, nothing is owed, and it is said once. A stop with no discharge
    /// held, after that, writes nothing and says nothing new.
    func testStartupLeavesAValueAnodeNeverWritesAloneAndSaysSoOnce() {
        let hw = FakeChargeHardware(percent: 77)
        hw.unknownValue = 0x04
        var lines: [String] = []
        let server = makeServer(hw, log: { lines.append($0) })
        server.clearOrphanedAdapterCut()
        XCTAssertTrue(hw.cutWrites.isEmpty, "a value nobody has measured was written over")
        XCTAssertEqual(lines.count, 1, "\(lines)")
        XCTAssertTrue(lines.first?.contains("0x04") ?? false, "\(lines)")
        XCTAssertFalse(server.reconnectOwed)
        XCTAssertTrue(server.isIdle)

        for _ in 0..<2 {
            let reply = server.handle(.command(.stopDischarge))
            XCTAssertTrue(reply.ok, reply.message)
            XCTAssertTrue(reply.message.contains("0x04"), reply.message)
        }
        XCTAssertTrue(hw.cutWrites.isEmpty, "a stop with nothing held wrote over it")
        XCTAssertEqual(lines.count, 1, "said more than once: \(lines)")
        XCTAssertEqual(hw.unknownValue, 0x04)
    }

    /// While a discharge is held, or a reconnect owed, the reconnect is written
    /// whatever the key reads — exactly as before.
    func testAHeldDischargeOrAnOwedReconnectIsWrittenWhateverTheKeyReads() {
        let hw = FakeChargeHardware(percent: 77)
        let server = makeServer(hw)
        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)
        hw.unknownValue = 0x0C
        XCTAssertTrue(server.handle(.command(.stopDischarge)).ok)
        XCTAssertEqual(hw.cutWrites, [true, false])
        XCTAssertNil(server.dischargeTarget)

        let owing = FakeChargeHardware(cut: true)
        owing.refuseRestore = true
        let other = makeServer(owing)
        other.clearOrphanedAdapterCut()
        XCTAssertTrue(other.reconnectOwed)
        owing.refuseRestore = false
        owing.unknownValue = 0x02
        other.watchDischarge()
        XCTAssertEqual(owing.cutWrites.last, false)
        XCTAssertEqual(owing.isCut, false)
        XCTAssertFalse(other.reconnectOwed)
    }

    /// A cut nobody owns that will not clear is not given up on: the helper
    /// stays up and the watch retries it.
    func testAnOrphanedCutThatWillNotClearIsRetried() {
        let hw = FakeChargeHardware(cut: true)
        hw.refuseRestore = true
        var lines: [String] = []
        let server = makeServer(hw, log: { lines.append($0) })
        server.clearOrphanedAdapterCut()
        XCTAssertTrue(lines.first?.hasPrefix("WARNING") ?? false, "\(lines)")
        XCTAssertTrue(server.reconnectOwed)
        XCTAssertFalse(server.isIdle)

        hw.refuseRestore = false
        server.watchDischarge()
        XCTAssertEqual(hw.isCut, false)
        XCTAssertTrue(server.isIdle)
    }

    func testIdleRuleCountsADischargeAsHolding() {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        let server = makeServer(hw)
        XCTAssertTrue(server.isIdle)
        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)
        XCTAssertFalse(server.isIdle, "an on-demand daemon would exit mid-discharge")
        XCTAssertTrue(server.handle(.command(.stopDischarge)).ok)
        XCTAssertTrue(server.isIdle)
    }

    // ── A held cut is always written back ──────────────────────────────────

    /// A HELD CUT PROVES THE KEY EXISTS: it read back cut. So when the watch
    /// fires and the key cannot be read — and the key-info question, failing
    /// too, answers "no such key" — the reconnect is written anyway, and the
    /// discharge is kept and owed until a read-back shows connected. It used to
    /// be called "this Mac has no adapter-cut key": nothing written, the target
    /// cleared, and the charger left cut with nobody watching.
    func testAHeldCutIsWrittenBackWhenTheKeyCannotBeRead() {
        let hw = FakeChargeHardware(percent: 77)
        var lines: [String] = []
        let server = makeServer(hw, log: { lines.append($0) })
        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)

        hw.keyExists = false
        hw.percent = 40
        server.watchDischarge()
        XCTAssertEqual(hw.cutWrites, [true, false, false, false], "the reconnect was skipped")
        XCTAssertEqual(server.dischargeTarget, 40)
        XCTAssertTrue(server.reconnectOwed)
        XCTAssertFalse(server.isIdle)
        XCTAssertFalse(lines.contains { $0.contains("no adapter-cut key") }, "\(lines)")

        server.watchDischarge()
        XCTAssertEqual(hw.cutWrites.count, 7, "the owed reconnect was not written again")
        XCTAssertEqual(server.dischargeTarget, 40, "cleared without a read-back")

        hw.keyExists = true
        server.watchDischarge()
        XCTAssertEqual(hw.isCut, false)
        XCTAssertNil(server.dischargeTarget)
        XCTAssertFalse(server.reconnectOwed)
        XCTAssertTrue(server.isIdle)
    }

    /// The same thing as it would happen on the hardware: the key is there and
    /// takes writes, ONE read fails, and the key-info question answers "no such
    /// key" because its own call failed. The reconnect is written, and read back.
    func testOneFailedReadDoesNotSkipTheReconnectOfAHeldCut() {
        let hw = FakeChargeHardware(percent: 77)
        let server = makeServer(hw)
        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)

        hw.failNextReads = 1
        hw.existsAnswersNo = true
        hw.percent = 40
        server.watchDischarge()
        XCTAssertEqual(hw.isCut, false, "the charger was left cut")
        XCTAssertEqual(hw.cutWrites.last, false)
        XCTAssertNil(server.dischargeTarget)
        XCTAssertTrue(server.isIdle)
    }

    /// Asked to stop while the key cannot be read: written, not explained away.
    func testStopDischargeWritesAHeldCutBackWhenTheKeyCannotBeRead() {
        let hw = FakeChargeHardware(percent: 77)
        let server = makeServer(hw)
        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)

        hw.keyExists = false
        let reply = server.handle(.command(.stopDischarge))
        XCTAssertFalse(reply.ok, reply.message)
        XCTAssertTrue(reply.message.contains("may still be cut off"), reply.message)
        XCTAssertEqual(hw.cutWrites, [true, false, false, false])
        XCTAssertEqual(server.dischargeTarget, 40)
        XCTAssertTrue(server.reconnectOwed)
    }

    /// `releaseAll` is the dead man's switch's own path (`release()`).
    func testReleaseAllWritesAHeldCutBackWhenTheKeyCannotBeRead() {
        let hw = FakeChargeHardware(percent: 77)
        let server = makeServer(hw)
        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)

        hw.keyExists = false
        XCTAssertFalse(server.handle(.command(.releaseAll)).ok)
        XCTAssertEqual(hw.cutWrites, [true, false, false, false])
        XCTAssertEqual(server.dischargeTarget, 40)
        XCTAssertFalse(server.isIdle)
    }

    /// The post-write "no such key" exit: a second discharge whose cut fails
    /// while one is held is undone with writes that cannot be read back. The
    /// held cut is still the helper's, still owed.
    func testAFailedCutWhileOneIsHeldKeepsTheHeldOneOwed() {
        let hw = FakeChargeHardware(percent: 77)
        let server = makeServer(hw)
        let clock = ChargeTestClock()
        server.now = { clock.now }
        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)

        hw.keyExists = false
        clock.advance(FanHelperServer.cutSpacing)
        XCTAssertFalse(server.handle(.command(.discharge(toPercent: 50))).ok)
        XCTAssertEqual(hw.cutWrites, [true, true, false, false, false])
        XCTAssertEqual(hw.isCut, true)
        XCTAssertEqual(server.dischargeTarget, 40)
        XCTAssertTrue(server.reconnectOwed)

        hw.keyExists = true
        server.watchDischarge()
        XCTAssertEqual(hw.isCut, false)
        XCTAssertTrue(server.isIdle)
    }

    // ── An undo that cannot be confirmed is owed ───────────────────────────

    /// A cut that did not read back is undone with a reconnect written whatever
    /// the key says. When that undo cannot be read back either, nobody knows
    /// whether the charger is cut: the reconnect is owed, so the helper is not
    /// idle and the watch keeps writing it.
    func testAnUndoThatCannotBeReadBackIsOwed() {
        let hw = FakeChargeHardware(percent: 77)
        hw.cutUnreadable = true
        hw.ignoreRestore = true
        let server = makeServer(hw)
        let reply = server.handle(.command(.discharge(toPercent: 40)))
        XCTAssertFalse(reply.ok, reply.message)
        XCTAssertTrue(reply.message.contains("may still be cut off"), reply.message)
        XCTAssertNil(server.dischargeTarget)
        XCTAssertEqual(hw.isCut, true)
        XCTAssertTrue(server.reconnectOwed, "an unconfirmed undo was forgotten")
        XCTAssertFalse(server.isIdle)

        hw.cutUnreadable = false
        hw.ignoreRestore = false
        server.watchDischarge()
        XCTAssertEqual(hw.isCut, false)
        XCTAssertFalse(server.reconnectOwed)
        XCTAssertTrue(server.isIdle)
    }

    /// A Mac with no `CHIE` at all: the cut is refused, the undo finds no such
    /// key, and nothing is owed — the helper must not stay up for ever there.
    func testADischargeOnAMacWithNoKeyIsRefusedAndOwesNothing() {
        let hw = FakeChargeHardware(percent: 77)
        hw.keyExists = false
        let server = makeServer(hw)
        let reply = server.handle(.command(.discharge(toPercent: 40)))
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.message, "the SMC would not cut the charger")
        XCTAssertNil(server.dischargeTarget)
        XCTAssertFalse(server.reconnectOwed)
        XCTAssertTrue(server.isIdle)
    }

    /// No new discharge while a reconnect is owed. An SMC refusing every
    /// charger write, on a charger that reads cut: the cut is refused and
    /// still reads 0x08, which counts as a cut. That used to answer
    /// "discharging to 50%" and clear the owed flag, hiding a reconnect known
    /// to be failing. Now it is refused, nothing is written, and the reconnect
    /// stays owed until a read shows it landed; then a discharge is taken again.
    func testADischargeIsRefusedWhileAReconnectIsOwed() {
        let hw = FakeChargeHardware(percent: 77, onAC: true, cut: true)
        hw.refuseRestore = true
        hw.refuseCut = true
        let server = makeServer(hw)
        server.clearOrphanedAdapterCut()
        XCTAssertTrue(server.reconnectOwed)
        let writesBefore = hw.cutWrites

        let reply = server.handle(.command(.discharge(toPercent: 50)))
        XCTAssertFalse(reply.ok, reply.message)
        XCTAssertEqual(reply.message, "the charger may still be cut off from an earlier failure")
        XCTAssertEqual(hw.cutWrites, writesBefore, "a refused discharge wrote to the charger")
        XCTAssertTrue(server.reconnectOwed, "the owed reconnect was forgotten")
        XCTAssertNil(server.dischargeTarget)
        XCTAssertFalse(server.isIdle)

        hw.refuseRestore = false
        hw.refuseCut = false
        server.watchDischarge()
        XCTAssertEqual(hw.isCut, false)
        XCTAssertFalse(server.reconnectOwed)

        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 50))).ok)
        XCTAssertEqual(hw.cutWrites.last, true)
        XCTAssertEqual(server.dischargeTarget, 50)
    }

    // ── Cuts are spaced ─────────────────────────────────────────────────────

    /// A CUT IS NOT TRIED AGAIN WITHIN TEN SECONDS of the last attempt. A
    /// client could otherwise switch the charger about once a second. The
    /// refusal writes nothing; a reconnect is never held back, before or after.
    func testACutIsNotTriedAgainWithinTenSecondsOfTheLast() {
        let hw = FakeChargeHardware(percent: 77)
        let server = makeServer(hw)
        let clock = ChargeTestClock()
        server.now = { clock.now }
        XCTAssertEqual(FanHelperServer.cutSpacing, 10)

        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)
        XCTAssertTrue(server.handle(.command(.stopDischarge)).ok, "a reconnect was held back")
        XCTAssertEqual(hw.cutWrites, [true, false])

        for wait in [1.0, 8.9] {
            clock.advance(wait)
            let reply = server.handle(.command(.discharge(toPercent: 40)))
            XCTAssertFalse(reply.ok, reply.message)
            XCTAssertEqual(reply.message, "the charger was switched a moment ago; try again shortly")
        }
        XCTAssertEqual(hw.cutWrites, [true, false], "a refused discharge wrote to the charger")
        XCTAssertNil(server.dischargeTarget)
        XCTAssertTrue(server.isIdle)

        clock.advance(0.1)   // ten seconds after the cut
        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)
        XCTAssertEqual(hw.cutWrites, [true, false, true])
        XCTAssertTrue(server.handle(.command(.stopDischarge)).ok, "a reconnect was held back")
        XCTAssertEqual(hw.isCut, false)
    }

    /// A cut the SMC refused is an attempt all the same: one that keeps being
    /// refused is not retried on every ask.
    func testARefusedCutCountsAsAnAttempt() {
        let hw = FakeChargeHardware(percent: 77)
        hw.refuseCut = true
        let server = makeServer(hw)
        let clock = ChargeTestClock()
        server.now = { clock.now }

        XCTAssertFalse(server.handle(.command(.discharge(toPercent: 40))).ok)
        let afterTheAttempt = hw.cutWrites
        XCTAssertEqual(afterTheAttempt.first, true)

        hw.refuseCut = false
        clock.advance(5)
        let reply = server.handle(.command(.discharge(toPercent: 40)))
        XCTAssertEqual(reply.message, "the charger was switched a moment ago; try again shortly")
        XCTAssertEqual(hw.cutWrites, afterTheAttempt)

        clock.advance(5)
        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)
        XCTAssertEqual(hw.isCut, true)
    }

    /// A clock set back is not a reason to hold every cut back until it
    /// catches up again.
    func testAClockSetBackDoesNotHoldCutsBack() {
        let hw = FakeChargeHardware(percent: 77)
        let server = makeServer(hw)
        let clock = ChargeTestClock()
        server.now = { clock.now }
        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)
        XCTAssertTrue(server.handle(.command(.stopDischarge)).ok)
        clock.advance(-3600)
        XCTAssertTrue(server.handle(.command(.discharge(toPercent: 40))).ok)
    }

    // ── Every answer to a discharge, word for word ─────────────────────────

    /// The app tells the helper's refusals apart by their exact words, so the
    /// words live on `ChargeRefusal`: the server sends those constants and the
    /// app compares against the same ones. Pinned twice over — each constant's
    /// text, and the whole reply the server sends, ok flag included — so
    /// neither the words nor which case sends them can drift unseen.
    func testEveryAnswerToADischargeIsPinned() {
        XCTAssertEqual(ChargeRefusal.noChargeControl, "this helper has no charge control")
        XCTAssertEqual(ChargeRefusal.noSleepNotices, "this Mac cannot warn the helper before it sleeps")
        XCTAssertEqual(ChargeRefusal.goingToSleep, "the Mac is going to sleep")
        XCTAssertEqual(ChargeRefusal.reconnectOwed, "the charger may still be cut off from an earlier failure")
        XCTAssertEqual(ChargeRefusal.targetOutOfRange, "refused: a discharge target must be 10–100%")
        XCTAssertEqual(ChargeRefusal.batteryUnreadable, "refused: the battery level cannot be read")
        XCTAssertEqual(ChargeRefusal.noCharger, "refused: no charger is connected")
        XCTAssertEqual(ChargeRefusal.atOrBelow(40), "refused: the battery is already at or below 40%")
        XCTAssertEqual(ChargeRefusal.switchedRecently, "the charger was switched a moment ago; try again shortly")
        XCTAssertEqual(ChargeRefusal.cutRefused, "the SMC would not cut the charger")
        XCTAssertEqual(ChargeRefusal.cutNotKept, "the SMC took the cut and the charger does not read as cut")

        func refused(_ message: String) -> FanReply { FanReply(ok: false, message: message) }
        func ask(_ server: FanHelperServer, _ target: Int) -> FanReply {
            server.handle(.command(.discharge(toPercent: target)))
        }

        // Already running: asked again within the spacing, refused with
        // nothing written; after it, the running discharge takes the new target.
        let running = FakeChargeHardware(percent: 77)
        let server = makeServer(running)
        let clock = ChargeTestClock()
        server.now = { clock.now }
        XCTAssertEqual(ask(server, 40), FanReply(ok: true, message: "discharging to 40%"))
        XCTAssertEqual(ask(server, 30), refused(ChargeRefusal.switchedRecently))
        XCTAssertEqual(running.cutWrites, [true])
        XCTAssertEqual(server.dischargeTarget, 40)
        clock.advance(FanHelperServer.cutSpacing)
        XCTAssertEqual(ask(server, 30), FanReply(ok: true, message: "discharging to 30%"))
        XCTAssertEqual(server.dischargeTarget, 30)

        // At or below the target, and the floor.
        XCTAssertEqual(ask(makeServer(FakeChargeHardware(percent: 40)), 40),
                       refused(ChargeRefusal.atOrBelow(40)))
        XCTAssertEqual(ask(makeServer(FakeChargeHardware(percent: 10)), 10),
                       refused(ChargeRefusal.atOrBelow(DischargeWatch.floor)))
        // No cable; a battery that cannot be read; a target out of range.
        XCTAssertEqual(ask(makeServer(FakeChargeHardware(percent: 77, onAC: false)), 40),
                       refused(ChargeRefusal.noCharger))
        XCTAssertEqual(ask(makeServer(FakeChargeHardware(percent: nil)), 40),
                       refused(ChargeRefusal.batteryUnreadable))
        XCTAssertEqual(ask(makeServer(FakeChargeHardware(percent: 77)), 9),
                       refused(ChargeRefusal.targetOutOfRange))

        // Asleep.
        let asleep = makeServer(FakeChargeHardware(percent: 77))
        asleep.systemWillSleep()
        XCTAssertEqual(ask(asleep, 40), refused(ChargeRefusal.goingToSleep))

        // A reconnect owed.
        let stuck = FakeChargeHardware(percent: 77, cut: true)
        stuck.refuseRestore = true
        let owing = makeServer(stuck)
        owing.clearOrphanedAdapterCut()
        XCTAssertEqual(ask(owing, 40), refused(ChargeRefusal.reconnectOwed))

        // No sleep notices.
        let deaf = makeServer(FakeChargeHardware(percent: 77))
        deaf.sleepNoticesUnavailable = true
        XCTAssertEqual(ask(deaf, 40), refused(ChargeRefusal.noSleepNotices))

        // A cut the SMC refused, and one it took and did not keep, each undone.
        let refusing = FakeChargeHardware(percent: 77)
        refusing.refuseCut = true
        XCTAssertEqual(ask(makeServer(refusing), 40), refused(ChargeRefusal.cutRefused))
        let ignoring = FakeChargeHardware(percent: 77)
        ignoring.ignoreCut = true
        XCTAssertEqual(ask(makeServer(ignoring), 40), refused(ChargeRefusal.cutNotKept))

        // No charge control at all.
        let bare = FanHelperServer(hardware: FakeFans([:]),
                                   configuration: .init(socketPath: "/unused", ownerUID: getuid(),
                                                        pin: .signingIdentifier("x")))
        XCTAssertEqual(ask(bare, 40), refused(ChargeRefusal.noChargeControl))
    }

    // ── A cut is judged by reading it back ─────────────────────────────────

    /// The result byte of a good `CHIE` write has never been measured. A cut
    /// that READS cut is a cut whatever the write answered: the answer is
    /// logged, and the discharge runs.
    func testACutThatReadsCutIsACutWhateverTheWriteAnswered() {
        let hw = FakeChargeHardware(percent: 77)
        hw.cutLandsButSaysNo = true
        var lines: [String] = []
        let server = makeServer(hw, log: { lines.append($0) })
        let reply = server.handle(.command(.discharge(toPercent: 40)))
        XCTAssertTrue(reply.ok, reply.message)
        XCTAssertEqual(server.dischargeTarget, 40)
        XCTAssertEqual(hw.cutWrites, [true], "a cut that read back was undone")
        XCTAssertEqual(hw.isCut, true)
        XCTAssertTrue(lines.contains { $0.contains("answered the cut with an error") }, "\(lines)")
    }

    /// A helper with no charge hardware refuses the charge commands rather than
    /// pretending.
    func testAHelperWithoutChargeHardwareRefuses() {
        let server = FanHelperServer(hardware: FakeFans([:]),
                                     configuration: .init(socketPath: "/unused", ownerUID: getuid(),
                                                          pin: .signingIdentifier("x")))
        XCTAssertFalse(server.handle(.command(.setChargeLimit(80))).ok)
        XCTAssertFalse(server.handle(.command(.discharge(toPercent: 40))).ok)
        XCTAssertFalse(server.handle(.command(.stopDischarge)).ok)
        XCTAssertNil(server.dischargeTarget)
    }
}

// ── The server, over a real socket ──────────────────────────────────────────

/// The dead man's switch only exists on the socket path: `dropClient` runs when
/// a real connection goes away, and the shutdown release when the loop ends.
final class ChargeHelperTestsSocket: XCTestCase {

    private var server: FanHelperServer!
    private var thread: Thread!
    private var link: FanControlLink!
    private var socketPath: String!
    /// Raw client sockets, and threads writing to them, cleaned up in order:
    /// the writers finish before their descriptors are closed.
    private var rawFDs: [Int32] = []
    private var writers: [Thread] = []

    override func tearDown() {
        link?.disconnect()
        spin(until: { self.writers.allSatisfy(\.isFinished) }, timeout: 3, failOnTimeout: false)
        for fd in rawFDs { close(fd) }
        rawFDs = []
        server?.stop()
        spin(until: { self.thread == nil || self.thread.isFinished }, timeout: 2)
        super.tearDown()
    }

    private func start(_ hw: FakeChargeHardware,
                       fans: FakeFans = FakeFans([:]),
                       watchEvery interval: TimeInterval? = nil,
                       connectLink: Bool = true,
                       log: ChargeLogRecorder? = nil,
                       configure: (FanHelperServer) -> Void = { _ in }) throws {
        socketPath = NSTemporaryDirectory() + "bs-chg-\(UUID().uuidString.prefix(8)).sock"
        guard let mine = ownCDHash() else {
            throw XCTSkip("no code identity available in this test environment")
        }
        server = FanHelperServer(hardware: fans,
                                 configuration: .init(socketPath: socketPath, ownerUID: getuid(),
                                                      pin: .exactBuild(cdhash: mine)),
                                 log: { log?.record($0) },
                                 charge: hw)
        server.chargeTiming = .immediate
        if let interval { server.dischargeWatchInterval = interval }
        configure(server)
        try server.start()
        thread = Thread { [server] in server?.run() }
        thread.start()
        link = FanControlLink(socketPath: socketPath)
        guard connectLink else { return }
        var status: FanControlLink.Status?
        link.connect { status = $0 }
        spin(until: { status != nil })
    }

    private func ownCDHash() -> String? {
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { return nil }
        defer { close(pair[0]); close(pair[1]) }
        return FanPeer.of(socket: pair[0])?.cdhash
    }

    private func send(_ command: FanCommand) -> FanReply {
        var result: FanReply?
        link.send(command) { result = $0 }
        spin(until: { result != nil })
        return result ?? FanReply(ok: false, message: "no reply")
    }

    /// A client that talks to the socket directly, so a test can send half a
    /// line — which `FanControlLink` never does.
    private func rawClient() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var addr = FanSocketIO.address(socketPath) else {
            throw XCTSkip("could not make a client socket")
        }
        guard FanSocketIO.withAddress(&addr, { p, len in Darwin.connect(fd, p, len) }) == 0 else {
            close(fd)
            throw XCTSkip("could not connect: \(String(cString: strerror(errno)))")
        }
        FanSocketIO.configure(fd, timeout: 2)    // SO_NOSIGPIPE, and a bounded read
        rawFDs.append(fd)
        return fd
    }

    private func rawRequest(_ fd: Int32, _ request: FanRequest) -> FanReply? {
        guard let data = try? FanWire.encode(request), FanSocketIO.writeAll(fd, data) else { return nil }
        var buffer = Data()
        guard let line = try? FanSocketIO.readLine(fd, buffer: &buffer) else { return nil }
        return try? FanWire.decode(FanReply.self, from: line)
    }

    /// One `{` every `interval`, never a newline, for `duration`.
    private func drip(_ fd: Int32, every interval: TimeInterval, for duration: TimeInterval) {
        let t = Thread {
            let end = Date().addingTimeInterval(duration)
            while Date() < end {
                var b: UInt8 = 0x7B
                if write(fd, &b, 1) < 0 { return }
                Thread.sleep(forTimeInterval: interval)
            }
        }
        writers.append(t)
        t.start()
    }

    // ── The dead man's switch ───────────────────────────────────────────────

    func testClientDropRestoresAdapterCut() throws {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        try start(hw)
        XCTAssertTrue(send(.discharge(toPercent: 40)).ok)
        XCTAssertEqual(hw.isCut, true)

        link.disconnect()
        spin(until: { hw.isCut == false })
        XCTAssertEqual(hw.isCut, false, "the charger stayed cut after the app went away")

        // And the target is gone with it: a target left set would keep an
        // on-demand daemon up forever, and show up here as a third write when
        // the helper stops.
        server.stop()
        spin(until: { self.thread.isFinished })
        XCTAssertNil(server.dischargeTarget)
        XCTAssertEqual(hw.cutWrites, [true, false])
    }

    /// RECONNECT FIRST, LOG AFTER. A log line is a write to whatever stderr is;
    /// the old order logged "client gone" before reconnecting, and a sink that
    /// failed there ended the process with the charger cut.
    func testNothingIsLoggedOnADropWhileTheChargerIsStillCut() throws {
        let hw = FakeChargeHardware(percent: 77)
        let log = ChargeLogRecorder(hw)
        try start(hw, log: log)
        XCTAssertTrue(send(.discharge(toPercent: 40)).ok)
        link.disconnect()
        spin(until: { log.lines.contains { $0.hasPrefix("client gone") } })

        let after = log.entries(after: "cut the charger")
        XCTAssertFalse(after.isEmpty)
        for entry in after {
            XCTAssertFalse(entry.cut, "logged with the charger still cut: \(entry.line)")
        }
    }

    func testNothingIsLoggedOnAStopWhileTheChargerIsStillCut() throws {
        let hw = FakeChargeHardware(percent: 77)
        let log = ChargeLogRecorder(hw)
        try start(hw, log: log)
        XCTAssertTrue(send(.discharge(toPercent: 40)).ok)
        server.stop()
        spin(until: { self.thread.isFinished })

        let after = log.entries(after: "cut the charger")
        XCTAssertTrue(after.contains { $0.line == "stopped" }, "\(after)")
        for entry in after {
            XCTAssertFalse(entry.cut, "logged with the charger still cut: \(entry.line)")
        }
    }

    /// The floor holds with the app connected and SILENT: the loop wakes on its
    /// own timer, looks at the battery, and reconnects at the target. The fake
    /// keeps answering that the cable is in while cut, as the hardware does.
    func testTheLoopReconnectsAtTheTargetWithNoRequest() throws {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        try start(hw, watchEvery: 0.05)
        XCTAssertTrue(send(.discharge(toPercent: 40)).ok)
        spin(until: { false }, timeout: 0.2, failOnTimeout: false)
        XCTAssertEqual(hw.isCut, true, "reconnected above the target")

        hw.percent = 40   // nothing is sent; only the timed wake can see this
        spin(until: { hw.isCut == false })
        XCTAssertEqual(hw.isCut, false, "the loop never checked the battery on its own")
    }

    /// The charge limit is macOS's own setting and is deliberately left where
    /// it was put when the app goes away.
    func testTheLimitIsNotUndoneWhenTheClientLeaves() throws {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        try start(hw)
        XCTAssertTrue(send(.setChargeLimit(63)).ok)
        link.disconnect()
        spin(until: { false }, timeout: 0.3, failOnTimeout: false)
        XCTAssertEqual(hw.limitWrites, [63])
        XCTAssertTrue(hw.cutWrites.isEmpty)
    }

    /// Every signal in `HelperSignals.stop` reaches the server as `stop()`.
    func testStoppingTheHelperRestoresAdapterCut() throws {
        let hw = FakeChargeHardware(percent: 77, onAC: true)
        try start(hw)
        XCTAssertTrue(send(.discharge(toPercent: 40)).ok)

        server.stop()
        spin(until: { self.thread.isFinished })
        XCTAssertEqual(hw.isCut, false, "the charger stayed cut after the helper stopped")
    }

    /// A fan AND a discharge, and the app goes away: both are handed back.
    func testDroppingTheClientHandsBackAHeldFanAndTheCharger() throws {
        let hw = FakeChargeHardware(percent: 77)
        let fans = FakeFans([0: .init(minRPM: 2317, maxRPM: 7826)])
        fans.seedTarget(0, 0)
        fans.seedMode(0, SMCFanMode.automatic)
        try start(hw, fans: fans)
        XCTAssertTrue(send(.setTarget(FanTarget(index: 0, rpm: 5000))).ok)
        XCTAssertTrue(send(.discharge(toPercent: 40)).ok)

        link.disconnect()
        spin(until: { hw.isCut == false && fans.targetWrites.count == 2 })
        XCTAssertEqual(hw.isCut, false)
        XCTAssertEqual(fans.targetWrites.map(\.rpm), [5000, 0], "the held fan was not handed back")
        XCTAssertEqual(fans.modeWrites.last?.mode, SMCFanMode.automatic)
    }

    // ── A client cannot hold the loop ───────────────────────────────────────

    /// THE FLOOR HOLDS WHILE A CLIENT DRIPS HALF A REQUEST. The old read waited
    /// for the newline, restarting its 5 s timeout on every byte, so one byte
    /// every few seconds kept the loop — and the floor check — away for hours.
    /// The line deadline is set long here, so the reconnect can only have come
    /// from the watch.
    func testAHalfSentRequestDoesNotHoldTheFloorCheck() throws {
        let hw = FakeChargeHardware(percent: 77)
        let log = ChargeLogRecorder(hw)
        try start(hw, watchEvery: 0.05, connectLink: false, log: log) {
            $0.requestLineDeadline = 30
        }
        let fd = try rawClient()
        XCTAssertEqual(rawRequest(fd, .command(.discharge(toPercent: 40)))?.ok, true)
        drip(fd, every: 0.1, for: 2)
        spin(until: { false }, timeout: 0.3, failOnTimeout: false)
        XCTAssertEqual(hw.isCut, true)

        hw.percent = 40
        let began = Date()
        spin(until: { hw.isCut == false }, timeout: 1.5)
        XCTAssertLessThan(Date().timeIntervalSince(began), 1.0,
                          "the floor check waited on a half-sent request")
        XCTAssertFalse(log.lines.contains { $0.hasPrefix("client gone") },
                       "the reconnect came from dropping the client, not from the watch")
    }

    /// A stop signal is acted on at once, whatever the client is doing.
    func testStoppingIsPromptWhileARequestIsHalfSent() throws {
        let hw = FakeChargeHardware(percent: 77)
        try start(hw, connectLink: false) { $0.requestLineDeadline = 30 }
        let fd = try rawClient()
        XCTAssertEqual(rawRequest(fd, .command(.discharge(toPercent: 40)))?.ok, true)
        var b: UInt8 = 0x7B
        XCTAssertEqual(write(fd, &b, 1), 1)
        spin(until: { false }, timeout: 0.2, failOnTimeout: false)

        let began = Date()
        server.stop()
        spin(until: { self.thread.isFinished }, timeout: 3)
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.5, "stop() waited on the client")
        XCTAssertEqual(hw.isCut, false)
    }

    /// A request that is never finished drops the client — counted from its
    /// first byte, however slowly the rest keeps coming — and the drop
    /// reconnects the charger.
    func testAClientThatNeverFinishesARequestIsDropped() throws {
        let hw = FakeChargeHardware(percent: 77)
        let log = ChargeLogRecorder(hw)
        try start(hw, connectLink: false, log: log) { $0.requestLineDeadline = 0.3 }
        let fd = try rawClient()
        XCTAssertEqual(rawRequest(fd, .command(.discharge(toPercent: 40)))?.ok, true)

        let began = Date()
        drip(fd, every: 0.05, for: 1.5)
        spin(until: { hw.isCut == false }, timeout: 1.4)
        XCTAssertLessThan(Date().timeIntervalSince(began), 1.0, "the drip kept extending its deadline")
        XCTAssertTrue(log.lines.contains { $0.contains("did not finish it") }, "\(log.lines)")
    }

    /// A client that sends and never reads its replies: the reply write gets
    /// one deadline, then the client is dropped and the charger reconnected.
    func testAClientThatNeverReadsItsRepliesIsDropped() throws {
        let hw = FakeChargeHardware(percent: 77)
        let log = ChargeLogRecorder(hw)
        try start(hw, connectLink: false, log: log) { $0.replyWriteDeadline = 0.2 }
        let fd = try rawClient()
        XCTAssertEqual(rawRequest(fd, .command(.discharge(toPercent: 40)))?.ok, true)

        let hello = try FanWire.encode(FanRequest.hello)
        let flood = Thread {
            var sent = 0
            while sent < 20_000, FanSocketIO.writeAll(fd, hello) { sent += 1 }
        }
        writers.append(flood)
        flood.start()
        spin(until: { hw.isCut == false }, timeout: 4)
        XCTAssertEqual(hw.isCut, false)
        XCTAssertTrue(log.lines.contains { $0.contains("stopped reading") }, "\(log.lines.suffix(3))")
    }

    // ── Both start paths, and the on-demand daemon ──────────────────────────

    /// The session helper's start path, `start()`.
    func testStartingTheSessionHelperClearsAnOrphanedCut() throws {
        let hw = FakeChargeHardware(percent: 77, onAC: true, cut: true)
        let path = NSTemporaryDirectory() + "bs-chg-\(UUID().uuidString.prefix(8)).sock"
        let session = FanHelperServer(hardware: FakeFans([:]),
                                      configuration: .init(socketPath: path, ownerUID: getuid(),
                                                           pin: .signingIdentifier("x")),
                                      charge: hw)
        session.chargeTiming = .immediate
        try session.start()
        defer { session.stop(); session.run() }   // run() unwinds at once and cleans up
        XCTAssertEqual(hw.isCut, false)
        XCTAssertEqual(hw.cutWrites, [false])
    }

    /// The installed daemon's start path, `start(adopting:)`. After a `kill -9` mid-discharge this
    /// is the only thing that reconnects the charger, the next time launchd
    /// starts a helper.
    func testAdoptingALaunchdSocketClearsAnOrphanedCut() throws {
        let hw = FakeChargeHardware(percent: 77, cut: true)
        let log = ChargeLogRecorder(hw)
        let path = NSTemporaryDirectory() + "bs-chg-\(UUID().uuidString.prefix(8)).sock"
        let listener = try XCTUnwrap(makeListeningSocket(at: path))
        defer { close(listener); unlink(path) }
        let adopting = FanHelperServer(hardware: FakeFans([:]),
                                       configuration: .init(socketPath: path, ownerUID: getuid(),
                                                            pin: .signingIdentifier("x")),
                                       log: { log.record($0) },
                                       charge: hw)
        adopting.chargeTiming = .immediate
        try adopting.start(adopting: listener)
        XCTAssertEqual(hw.isCut, false)
        XCTAssertEqual(hw.cutWrites, [false])
        XCTAssertTrue(log.lines.contains("cleared an adapter cut nobody owned"), "\(log.lines)")
        adopting.stop()
    }

    /// The RUN LOOP's idle rule, not only `isIdle`: an on-demand helper whose
    /// reconnect is failing must not time out and leave the charger cut. It
    /// leaves once the reconnect lands.
    func testAnOnDemandHelperStaysUpUntilTheChargerIsReconnected() throws {
        let hw = FakeChargeHardware(percent: 77)
        try start(hw, watchEvery: 0.05) { $0.idleExit = 0.3 }
        XCTAssertTrue(send(.discharge(toPercent: 40)).ok)

        hw.refuseRestore = true
        link.disconnect()
        spin(until: { false }, timeout: 1.0, failOnTimeout: false)
        XCTAssertFalse(thread.isFinished, "an on-demand helper exited with the charger still cut")
        XCTAssertEqual(hw.isCut, true)

        hw.refuseRestore = false
        spin(until: { self.thread.isFinished }, timeout: 3)
        XCTAssertTrue(thread.isFinished, "it never left once there was nothing to hold")
        XCTAssertEqual(hw.isCut, false)
    }

    /// The app goes away while the key cannot be read. The held cut is written
    /// back, and — not read back — still owed: the on-demand helper stays up
    /// and keeps writing until a read shows connected. It used to call this
    /// "no adapter-cut key", clear the target and idle out with the charger cut.
    func testAnOnDemandHelperStaysUpWhenAHeldCutCannotBeReadBack() throws {
        let hw = FakeChargeHardware(percent: 77)
        let log = ChargeLogRecorder(hw)
        try start(hw, watchEvery: 0.05, log: log) { $0.idleExit = 0.3 }
        XCTAssertTrue(send(.discharge(toPercent: 40)).ok)

        hw.keyExists = false
        link.disconnect()
        spin(until: { false }, timeout: 1.0, failOnTimeout: false)
        XCTAssertFalse(thread.isFinished, "an on-demand helper exited with the charger still cut")
        XCTAssertEqual(hw.isCut, true)
        XCTAssertGreaterThan(hw.cutWrites.count, 4, "the watch did not keep writing the reconnect")
        XCTAssertFalse(log.lines.contains { $0.contains("no adapter-cut key") }, "\(log.lines)")

        hw.keyExists = true
        spin(until: { self.thread.isFinished }, timeout: 3)
        XCTAssertTrue(thread.isFinished, "it never left once the charger read connected")
        XCTAssertEqual(hw.isCut, false)
    }

    /// A stop signal while the key cannot be read: the process is leaving, and
    /// the one thing it can still do — write the reconnect — it does.
    func testStoppingWritesAHeldCutBackWhenTheKeyCannotBeRead() throws {
        let hw = FakeChargeHardware(percent: 77)
        let log = ChargeLogRecorder(hw)
        try start(hw, log: log)
        XCTAssertTrue(send(.discharge(toPercent: 40)).ok)

        hw.keyExists = false
        server.stop()
        spin(until: { self.thread.isFinished })
        XCTAssertEqual(hw.cutWrites, [true, false, false, false], "the reconnect was skipped")
        XCTAssertFalse(log.lines.contains { $0.contains("no adapter-cut key") }, "\(log.lines)")
    }

    /// The undo of a cut that did not read back, not read back itself, and the
    /// app goes away: the on-demand helper stays up until a read shows connected.
    func testAnOnDemandHelperStaysUpWhileAnUndoIsUnconfirmed() throws {
        let hw = FakeChargeHardware(percent: 77)
        try start(hw, watchEvery: 0.05) { $0.idleExit = 0.3 }
        hw.cutUnreadable = true
        hw.ignoreRestore = true
        XCTAssertFalse(send(.discharge(toPercent: 40)).ok)

        link.disconnect()
        spin(until: { false }, timeout: 1.0, failOnTimeout: false)
        XCTAssertFalse(thread.isFinished, "an on-demand helper exited owing an unconfirmed reconnect")
        XCTAssertEqual(hw.isCut, true)

        hw.cutUnreadable = false
        hw.ignoreRestore = false
        spin(until: { self.thread.isFinished }, timeout: 3)
        XCTAssertTrue(thread.isFinished, "it never left once the charger read connected")
        XCTAssertEqual(hw.isCut, false)
    }

    private func makeListeningSocket(at path: String) -> Int32? {
        guard var addr = FanSocketIO.address(path) else { return nil }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        guard FanSocketIO.withAddress(&addr, { p, len in Darwin.bind(fd, p, len) }) == 0,
              listen(fd, 4) == 0 else { close(fd); return nil }
        return fd
    }

    private func spin(until done: () -> Bool, timeout: TimeInterval = 3,
                      failOnTimeout: Bool = true,
                      file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if done() { return }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        if failOnTimeout && !done() {
            XCTFail("timed out after \(timeout)s", file: file, line: line)
        }
    }
}

/// Every log line the server writes, with whether the charger was cut at the
/// moment it was written.
final class ChargeLogRecorder {
    private let lock = NSLock()
    private let hw: FakeChargeHardware
    private var recorded: [(line: String, cut: Bool)] = []

    init(_ hw: FakeChargeHardware) { self.hw = hw }

    func record(_ line: String) {
        let cut = hw.isCut
        lock.lock(); recorded.append((line, cut)); lock.unlock()
    }

    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return recorded.map(\.line)
    }

    /// The lines after the first one starting with `prefix`.
    func entries(after prefix: String) -> [(line: String, cut: Bool)] {
        lock.lock(); defer { lock.unlock() }
        guard let i = recorded.firstIndex(where: { $0.line.hasPrefix(prefix) }) else { return [] }
        return Array(recorded[(i + 1)...])
    }
}

/// A clock a test moves by hand, for the server's `now`. Locked: the socket
/// tests read it from the server's thread.
final class ChargeTestClock {
    private let lock = NSLock()
    private var current = Date(timeIntervalSinceReferenceDate: 1_000_000)

    var now: Date { lock.lock(); defer { lock.unlock() }; return current }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); current += seconds; lock.unlock()
    }
}

// ── The fake ────────────────────────────────────────────────────────────────

/// Charge hardware that records instead of writing. Locked because the socket
/// tests touch it from the server's thread and inspect it from the main one.
///
/// It answers as the hardware does: `onAC()` is whether the cable is in, cut or
/// not (`ChargeAC.presence` reads the charger's own details, which a cut leaves
/// alone). A test pulls the cable by setting `cable`; `acWhileCut` overrides the
/// answer for a cut alone.
final class FakeChargeHardware: ChargeHardware {
    private let lock = NSLock()
    private var _percent: Int?
    /// Whether the cable is in; nil when that cannot be read.
    private var _cable: Bool?
    /// What `onAC()` answers while the charger is cut, when that is not the
    /// cable's.
    private var _acWhileCut: Bool?
    /// What the charger is actually doing.
    private var _cut: Bool
    private var _unreadable = false
    private var _keyExists = true
    private var _cutWrites: [Bool] = []
    private var _limitWrites: [Int] = []
    private var _refuseCut = false
    private var _refuseRestore = false
    private var _ignoreCut = false
    private var _ignoreRestore = false
    private var _restoreRefusalsLeft = 0
    private var _refuseLimit = false
    private var _cutLandsButSaysNo = false
    private var _failNextReads = 0
    private var _existsAnswersNo = false
    private var _unknownValue: UInt8?

    init(percent: Int? = 50, onAC: Bool? = true, cut: Bool = false) {
        _percent = percent; _cable = onAC; _cut = cut
    }

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }

    var percent: Int? {
        get { locked { _percent } }
        set { locked { _percent = newValue } }
    }
    var cable: Bool? {
        get { locked { _cable } }
        set { locked { _cable = newValue } }
    }
    var acWhileCut: Bool? {
        get { locked { _acWhileCut } }
        set { locked { _acWhileCut = newValue } }
    }
    /// The charger's real state, whatever a read would say.
    var isCut: Bool { locked { _cut } }
    var cutWrites: [Bool] { locked { _cutWrites } }
    var limitWrites: [Int] { locked { _limitWrites } }
    /// The key exists, and reads of it fail.
    var cutUnreadable: Bool {
        get { locked { _unreadable } }
        set { locked { _unreadable = newValue } }
    }
    var keyExists: Bool {
        get { locked { _keyExists } }
        set { locked { _keyExists = newValue } }
    }
    /// The SMC says no, and nothing changes.
    var refuseCut: Bool {
        get { locked { _refuseCut } }
        set { locked { _refuseCut = newValue } }
    }
    var refuseRestore: Bool {
        get { locked { _refuseRestore } }
        set { locked { _refuseRestore = newValue } }
    }
    /// The SMC says yes, and nothing changes.
    var ignoreCut: Bool {
        get { locked { _ignoreCut } }
        set { locked { _ignoreCut = newValue } }
    }
    var ignoreRestore: Bool {
        get { locked { _ignoreRestore } }
        set { locked { _ignoreRestore = newValue } }
    }
    /// Refuse this many reconnects, then take them.
    var restoreRefusalsLeft: Int {
        get { locked { _restoreRefusalsLeft } }
        set { locked { _restoreRefusalsLeft = newValue } }
    }
    var refuseLimitWrites: Bool {
        get { locked { _refuseLimit } }
        set { locked { _refuseLimit = newValue } }
    }
    /// The SMC applies the cut and answers no: a write whose result byte is
    /// not 0 although it landed. Unmeasured on real hardware, so possible.
    var cutLandsButSaysNo: Bool {
        get { locked { _cutLandsButSaysNo } }
        set { locked { _cutLandsButSaysNo = newValue } }
    }
    /// This many reads of the key fail, then reads work again. The key is
    /// there and takes writes throughout.
    var failNextReads: Int {
        get { locked { _failNextReads } }
        set { locked { _failNextReads = newValue } }
    }
    /// `adapterCutKeyExists()` answers no while the key is there and takes
    /// writes — what `SMC.exists` answers for any key-info call that fails.
    var existsAnswersNo: Bool {
        get { locked { _existsAnswersNo } }
        set { locked { _existsAnswersNo = newValue } }
    }
    /// The key holds a value Anode never writes — neither 0x00 nor 0x08 — and
    /// reads answer it until a write lands. Whatever put it there, it was not
    /// Anode.
    var unknownValue: UInt8? {
        get { locked { _unknownValue } }
        set { locked { _unknownValue = newValue } }
    }

    func adapterCutValue() -> UInt8? {
        locked {
            if _failNextReads > 0 { _failNextReads -= 1; return nil }
            if _unreadable || !_keyExists { return nil }
            return _unknownValue ?? (_cut ? AdapterCutKey.cut : AdapterCutKey.connected)
        }
    }
    func adapterCut() -> Bool? {
        adapterCutValue().map { $0 != AdapterCutKey.connected }
    }
    func setAdapterCut(_ on: Bool) -> Bool {
        locked {
            _cutWrites.append(on)
            guard _keyExists else { return false }
            if on {
                if _refuseCut { return false }
                if _ignoreCut { return true }
                if _cutLandsButSaysNo { _cut = true; _unknownValue = nil; return false }
            } else {
                if _restoreRefusalsLeft > 0 { _restoreRefusalsLeft -= 1; return false }
                if _refuseRestore { return false }
                if _ignoreRestore { return true }
            }
            _cut = on
            _unknownValue = nil
            return true
        }
    }
    func batteryPercent() -> Int? { locked { _percent } }
    func onAC() -> Bool? { locked { _cut ? (_acWhileCut ?? _cable) : _cable } }
    func adapterCutKeyExists() -> Bool { locked { _keyExists && !_existsAnswersNo } }
    func writeChargeLimit(_ percent: Int) -> Bool {
        locked {
            _limitWrites.append(percent)
            return !_refuseLimit
        }
    }
}
