import XCTest
@testable import BetterStatsApp
@testable import PowerKit

// The Fans tab's control strip, tested as arithmetic.
//
// Two things happen behind this strip that nothing else in this app does: a root
// process gets STARTED, and a fan gets WRITTEN. Both are decided by `FanSession`,
// which is why it has no view and no socket in it — every branch below is a claim
// that can be checked without root, without a running helper, and without
// spinning a fan to find out.
//
// NOTHING HERE TOUCHES A FAN, and nothing here starts a helper.

private let realLimits = FanPolicy.Limits(minRPM: 2317, maxRPM: 7826)

final class FanSessionTests: XCTestCase {

    private func connected(fans: Int = 2) -> FanSession {
        FanSession(enabled: true, helper: .connected(fanCount: fans))
    }

    private func automatic() -> FanSession {
        FanSession(enabled: true, helper: .absent)
    }

    // ── Connecting is not controlling ───────────────────────────────────────

    /// The handshake writes nothing, so a helper that is merely CONNECTED has
    /// changed no fan. Calling that state "manual control" would put the strip's
    /// most alarming label on a machine macOS is still deciding for.
    func testConnectingIsNotControl() {
        let session = connected()
        XCTAssertEqual(session.mode, .automatic)
        XCTAssertFalse(session.isDriving)
        XCTAssertNil(session.asked(0))
    }

    // ── Grabbing a knob ─────────────────────────────────────────────────────

    /// The helper is already running, so there is nothing to authorise and no
    /// prompt of any kind: a grab is one socket write.
    func testAGrabWithAHelperRunningJustSendsIt() {
        var session = connected()
        let effect = session.apply(.setSpeed(index: 1, rpm: 4000, limits: realLimits))
        XCTAssertEqual(effect, .send(.setTarget(FanTarget(index: 1, rpm: 4000))))
        XCTAssertEqual(session.asked(1), 4000)
        XCTAssertEqual(session.mode, .manual(fans: 1))
    }

    /// No helper: the answer is a visible privileged step, and NOTHING is held
    /// yet. A strip that claimed manual control before a single byte reached a
    /// root process would be lying about the state of the hardware.
    func testAGrabWithNoHelperAsksForTheOnePrivilegedStep() {
        var session = automatic()
        XCTAssertEqual(session.apply(.setSpeed(index: 0, rpm: 5000, limits: realLimits)),
                       .startHelper)
        XCTAssertEqual(session.mode, .starting)
        XCTAssertEqual(session.held, [:], "nothing is held until a helper answers")
        XCTAssertEqual(session.pending, [0: 5000])
        XCTAssertEqual(session.asked(0), 5000, "the knob stays where the user left it")
    }

    func testTheQueuedRequestGoesTheMomentTheHelperAnswers() {
        var session = automatic()
        _ = session.apply(.setSpeed(index: 0, rpm: 5000, limits: realLimits))
        let queued = session.helperBecame(.connected(fanCount: 2))
        XCTAssertEqual(queued, [.setTarget(FanTarget(index: 0, rpm: 5000))])
        XCTAssertEqual(session.held, [0: 5000])
        XCTAssertEqual(session.pending, [:])
        XCTAssertEqual(session.mode, .manual(fans: 1))
    }

    /// On a two-fan machine a user can easily set both while the password prompt
    /// is still up. Dropping the first would leave a knob sitting at a speed
    /// nothing was ever told about.
    func testBothKnobsMovedWhileWaitingAreKeptInFanOrder() {
        var session = automatic()
        _ = session.apply(.setSpeed(index: 1, rpm: 6000, limits: realLimits))
        let second = session.apply(.setSpeed(index: 0, rpm: 3000, limits: realLimits))
        XCTAssertEqual(second, .nothing("Waiting for the fan helper — finish the prompt in Terminal."))
        XCTAssertEqual(session.helperBecame(.connected(fanCount: 2)),
                       [.setTarget(FanTarget(index: 0, rpm: 3000)),
                        .setTarget(FanTarget(index: 1, rpm: 6000))])
        XCTAssertEqual(session.mode, .manual(fans: 2))
    }

    /// The same knob moved twice while waiting is one request, not two.
    func testTheLastValueOnOneKnobWins() {
        var session = automatic()
        _ = session.apply(.setSpeed(index: 0, rpm: 3000, limits: realLimits))
        _ = session.apply(.setSpeed(index: 0, rpm: 6000, limits: realLimits))
        XCTAssertEqual(session.helperBecame(.connected(fanCount: 2)),
                       [.setTarget(FanTarget(index: 0, rpm: 6000))])
    }

    // ── Cancelling ──────────────────────────────────────────────────────────

    /// ✕ while the helper is being started. Nothing was written, so this is a
    /// cancel and not a release: no half-state, no knob left enabled with nothing
    /// behind it.
    func testCancellingTheStartLeavesNothingBehind() {
        var session = automatic()
        _ = session.apply(.setSpeed(index: 0, rpm: 5000, limits: realLimits))
        XCTAssertEqual(session.apply(.release), .abandonStart)
        XCTAssertEqual(session.mode, .automatic)
        XCTAssertEqual(session.pending, [:])
        XCTAssertEqual(session.held, [:])
        XCTAssertNil(session.asked(0), "the knob goes back to reading the fan")
    }

    /// The user cancelled the authentication, or closed the window, or never
    /// typed anything. The strip has to come all the way back on its own.
    func testAHelperThatNeverArrivesReturnsToAutomatic() {
        var session = automatic()
        _ = session.apply(.fullSpeed(index: 0, limits: realLimits))
        XCTAssertEqual(session.helperBecame(.absent), [])
        XCTAssertEqual(session.mode, .automatic)
        XCTAssertEqual(session.pending, [:])
        XCTAssertNil(session.asked(0))
    }

    /// "Nothing is listening" while a helper is still being started is not news,
    /// and must not throw away what the user queued.
    func testStillWaitingKeepsTheQueuedRequest() {
        var session = automatic()
        _ = session.apply(.setSpeed(index: 0, rpm: 5000, limits: realLimits))
        XCTAssertEqual(session.helperBecame(.starting), [])
        XCTAssertEqual(session.pending, [0: 5000])
        XCTAssertEqual(session.mode, .starting)
    }

    // ── ❄︎ ──────────────────────────────────────────────────────────────────

    /// "100%" is the top of the fan's OWN reported range, not a number this app
    /// picked. The helper re-clamps against limits it reads itself, and the two
    /// have to mean the same thing.
    func testTheSnowflakeAsksForTheFansOwnMaximum() {
        var session = connected()
        XCTAssertEqual(session.apply(.fullSpeed(index: 0, limits: realLimits)),
                       .send(.setTarget(FanTarget(index: 0, rpm: 7826))))
        XCTAssertEqual(session.asked(0), 7826)
    }

    /// ❄︎ takes the same route as a grab when nothing is running — it is a
    /// shortcut for a speed, not a shortcut around the privileged step.
    func testTheSnowflakeStartsTheHelperToo() {
        var session = automatic()
        XCTAssertEqual(session.apply(.fullSpeed(index: 1, limits: realLimits)), .startHelper)
        XCTAssertEqual(session.pending, [1: 7826])
    }

    // ── ✕ ──────────────────────────────────────────────────────────────────

    /// There is no per-fan release. The helper's whole privileged vocabulary is
    /// "set one fan" and "release the fans", and faking a single-fan release by
    /// writing that fan its minimum would PIN it there — quietly — which is the
    /// exact failure this button exists to undo.
    func testTheCrossReleasesEveryFanBecauseThereIsNoOtherRelease() {
        var session = connected()
        _ = session.apply(.setSpeed(index: 0, rpm: 5000, limits: realLimits))
        XCTAssertEqual(session.apply(.release), .send(.releaseAll))
    }

    /// Releasing fans nobody is holding would be a privileged write for nothing.
    func testTheCrossDoesNotTalkToTheHelperWhenNothingIsHeld() {
        var session = connected()
        XCTAssertEqual(session.apply(.release), .nothing("The fans are already on automatic."))
    }

    /// A release that half-failed leaves fans pinned. A strip that had already
    /// gone quiet would be the one place a user could not see that.
    func testAFailedReleaseKeepsTheStripSayingManual() {
        var session = connected()
        _ = session.apply(.setSpeed(index: 0, rpm: 5000, limits: realLimits))
        _ = session.apply(.release)
        session.completed(.releaseAll, ok: false)
        XCTAssertEqual(session.mode, .manual(fans: 1))
        XCTAssertEqual(session.asked(0), 5000)
    }

    func testASuccessfulReleaseReturnsToAutomatic() {
        var session = connected()
        _ = session.apply(.setSpeed(index: 0, rpm: 5000, limits: realLimits))
        _ = session.apply(.setSpeed(index: 1, rpm: 6000, limits: realLimits))
        _ = session.apply(.release)
        session.completed(.releaseAll, ok: true)
        XCTAssertEqual(session.mode, .automatic)
        XCTAssertFalse(session.isDriving)
        XCTAssertNil(session.asked(0))
        XCTAssertNil(session.asked(1))
    }

    /// A refusal means the helper is gone or said no; either way the strip has to
    /// stop claiming the fan is where the knob is.
    func testAFailedSetStopsTheKnobClaimingTheFan() {
        var session = connected()
        _ = session.apply(.setSpeed(index: 0, rpm: 5000, limits: realLimits))
        _ = session.apply(.setSpeed(index: 1, rpm: 6000, limits: realLimits))
        session.completed(.setTarget(FanTarget(index: 0, rpm: 5000)), ok: false)
        XCTAssertNil(session.asked(0))
        XCTAssertEqual(session.asked(1), 6000, "one refusal is not a general retreat")
        XCTAssertEqual(session.mode, .manual(fans: 1))
    }

    // ── The helper goes away ────────────────────────────────────────────────

    /// ⌃C in the Terminal window, or a crash, or a kill. The helper releases the
    /// fans when its client disappears and again on its own way out, so the fans
    /// are already back on automatic — and a knob still claiming a target would
    /// be the only thing on screen that had not noticed.
    func testAHelperThatDiesMidSessionTakesEveryClaimWithIt() {
        var session = connected()
        _ = session.apply(.setSpeed(index: 0, rpm: 5000, limits: realLimits))
        _ = session.apply(.setSpeed(index: 1, rpm: 6000, limits: realLimits))
        XCTAssertEqual(session.mode, .manual(fans: 2))

        XCTAssertEqual(session.helperBecame(.absent), [])
        XCTAssertEqual(session.mode, .automatic)
        XCTAssertFalse(session.isDriving)
        XCTAssertNil(session.asked(0))
        XCTAssertNil(session.asked(1))
    }

    /// The ordinary cause is a rebuild. The strip repeats the helper's own words
    /// rather than pretending to drive anything.
    func testARefusedHelperRepeatsItsReasonInsteadOfDriving() {
        var session = connected()
        _ = session.apply(.setSpeed(index: 0, rpm: 5000, limits: realLimits))
        session.helperBecame(.refused("caller is not the build this helper was started for"))
        XCTAssertEqual(session.mode,
                       .blocked("caller is not the build this helper was started for"))
        XCTAssertFalse(session.isDriving)
        XCTAssertEqual(session.apply(.setSpeed(index: 0, rpm: 4000, limits: realLimits)),
                       .nothing("caller is not the build this helper was started for"))
    }

    // ── Off ─────────────────────────────────────────────────────────────────

    /// `fanControlEnabled` ships false, and its contract is that the machine is
    /// one this code has never written to. A gesture while off must not open a
    /// socket, start a helper, or send anything.
    func testNothingHappensWhileTheFeatureIsOff() {
        var session = FanSession(enabled: false, helper: .connected(fanCount: 2))
        XCTAssertEqual(session.mode, .off)
        for gesture: FanSession.Gesture in [.setSpeed(index: 0, rpm: 7000, limits: realLimits),
                                           .fullSpeed(index: 0, limits: realLimits),
                                           .release] {
            XCTAssertEqual(session.apply(gesture),
                           .nothing("Fan control is off — macOS is deciding."))
        }
        XCTAssertFalse(session.isDriving)
    }

    // ── The safety floor, on the app's side of the socket ───────────────────

    /// The slider cannot be dragged below the fan's minimum, but the value that
    /// reaches the command is clamped anyway. The helper clamps again against
    /// limits it reads itself — that is the boundary that counts — and this is
    /// the belt: a request below the floor becomes the floor, never a stop.
    func testATargetBelowTheFansMinimumIsRaisedRatherThanSent() {
        var session = connected()
        XCTAssertEqual(session.apply(.setSpeed(index: 0, rpm: 0, limits: realLimits)),
                       .send(.setTarget(FanTarget(index: 0, rpm: 2317))))
        XCTAssertEqual(session.apply(.setSpeed(index: 0, rpm: -4000, limits: realLimits)),
                       .send(.setTarget(FanTarget(index: 0, rpm: 2317))))
        XCTAssertEqual(session.asked(0), 2317)
    }

    func testATargetAboveTheFansMaximumIsClamped() {
        var session = connected()
        XCTAssertEqual(session.apply(.setSpeed(index: 0, rpm: 99_999, limits: realLimits)),
                       .send(.setTarget(FanTarget(index: 0, rpm: 7826))))
    }

    /// A fan whose reported max is at or below its min is a misread key. Asking a
    /// user to authenticate a root process for a fan that could never be written
    /// is a password prompt for nothing.
    func testAFanWithImplausibleLimitsNeverStartsAHelper() {
        var session = automatic()
        let effect = session.apply(.setSpeed(index: 0, rpm: 3000,
                                             limits: .init(minRPM: 5000, maxRPM: 1000)))
        XCTAssertEqual(effect, .nothing("Fan 1 does not report a usable speed range, "
                                      + "so it is left on automatic."))
        XCTAssertEqual(session.mode, .automatic)
        XCTAssertEqual(session.pending, [:])
    }

    func testANaNTargetIsRefusedRatherThanWritten() {
        var session = connected()
        guard case .nothing = session.apply(.setSpeed(index: 0, rpm: .nan,
                                                      limits: realLimits)) else {
            return XCTFail("a NaN target reached the helper")
        }
        XCTAssertFalse(session.isDriving)
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// The slider is a gauge before it is a control, and that is the part most likely
/// to be got wrong quietly: a strip that looks disabled AND reads zero is
/// indistinguishable from a broken pane.
final class FanGaugeTests: XCTestCase {

    /// Automatic mode. The knob has to follow the hardware, or the control reads
    /// as dead — which this pane has already been mistaken for once.
    func testTheKnobIsALiveGaugeWhenNothingHasBeenAskedFor() {
        XCTAssertEqual(FanGauge.knobRPM(current: 3400, asked: nil, limits: realLimits), 3400)
        XCTAssertEqual(FanGauge.knobRPM(current: 5000, asked: nil, limits: realLimits), 5000)
    }

    /// A cool fan parks at 0 rpm, which is BELOW its own minimum and simply not on
    /// this slider's scale. The knob sits at the bottom of its travel rather than
    /// off the end of it — and never at a position that would mean "stop".
    func testAParkedFanSitsAtTheBottomOfItsTravelRatherThanOffTheScale() {
        XCTAssertEqual(FanGauge.knobRPM(current: 0, asked: nil, limits: realLimits), 2317)
    }

    /// A fan takes seconds to reach a new target. Yanking the knob back to the
    /// current reading mid-spin-up reads as the control fighting the user.
    func testTheKnobHoldsWhatWasAskedForRatherThanChasingTheFan() {
        XCTAssertEqual(FanGauge.knobRPM(current: 2400, asked: 6000, limits: realLimits), 6000)
    }

    func testAnAskedForValueIsNeverShownBelowTheFansMinimum() {
        XCTAssertEqual(FanGauge.knobRPM(current: 3000, asked: 0, limits: realLimits), 2317)
        XCTAssertEqual(FanGauge.knobRPM(current: 3000, asked: -1, limits: realLimits), 2317)
        XCTAssertEqual(FanGauge.knobRPM(current: 3000, asked: 99_999, limits: realLimits), 7826)
    }

    /// A misread limit pair must not put the knob somewhere that means less than
    /// the fan's own floor.
    func testImplausibleLimitsPinTheKnobToTheMinimum() {
        let bad = FanPolicy.Limits(minRPM: 5000, maxRPM: 1000)
        XCTAssertEqual(FanGauge.knobRPM(current: 3000, asked: nil, limits: bad), 5000)
        XCTAssertEqual(FanGauge.knobRPM(current: .nan, asked: nil, limits: realLimits), 2317)
    }

    /// Two numbers only when there are two facts. In automatic there is no target
    /// of ours to show, and printing the knob's position as one would claim this
    /// app had asked for a speed it never asked for.
    func testTheReadoutClaimsNoTargetInAutomatic() {
        XCTAssertEqual(FanGauge.readout(current: 2451, asked: nil), "2451 rpm")
        XCTAssertFalse(FanGauge.readout(current: 0, asked: nil).contains("→"))
    }

    func testTheReadoutShowsBothNumbersWhileDriving() {
        XCTAssertEqual(FanGauge.readout(current: 2451, asked: 6000), "2451 → 6000 rpm")
    }

    func testAnUnreadableSpeedIsADashRatherThanAZero() {
        XCTAssertEqual(FanGauge.readout(current: .nan, asked: nil), "— rpm")
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// How the helper actually gets started.
///
/// The app cannot become root and must not pretend to, so it opens a Terminal
/// window on a script that PRINTS THE COMMAND FIRST. That ordering is the whole
/// security argument for the feature — nothing verifies the helper before it runs
/// as root except the user reading the path — so it is asserted here rather than
/// discovered in a Terminal window.
final class FanHelperLaunchTests: XCTestCase {

    private let command = "sudo '/Users/x/Applications/BetterStats.app/Contents/MacOS/BetterStatsHelper'"

    func testTheScriptIsAShellScriptThatExecsTheCommand() {
        let script = FanHelperLaunch.script(command: command)
        XCTAssertTrue(script.hasPrefix("#!/bin/sh"), script)
        // exec, not a plain call: ⌃C then reaches the helper directly, and ⌃C is
        // the documented and only way to stop it.
        XCTAssertTrue(script.contains("exec \(command)"), script)
    }

    /// The command is shown BEFORE it is run. A user who reads the path after
    /// authenticating has not checked anything.
    func testTheCommandIsPrintedBeforeItIsRun() throws {
        let script = FanHelperLaunch.script(command: command)
        let shown = try XCTUnwrap(script.range(of: "printf"))
        let run = try XCTUnwrap(script.range(of: "exec "))
        XCTAssertTrue(shown.lowerBound < run.lowerBound,
                      "the path would be authorised before it was shown")
    }

    /// It has to be valid shell, and it cannot be tried out to find out — running
    /// it would start a root process. So it is PARSED instead: `sh -n` checks the
    /// syntax and executes nothing, which is the only way to catch the mistake
    /// that would break this feature completely and silently, a heredoc that
    /// never terminates.
    func testTheScriptParsesAsShellWithoutRunningAnything() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bs-fan-script-\(UUID().uuidString).sh")
        try FanHelperLaunch.script(command: command)
            .write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-n", url.path]   // parse only
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0,
                       "the command that starts fan control is not valid shell")
    }

    /// The banner has to say what a person needs to decide with: that this runs
    /// as root, and how to stop it.
    func testTheBannerSaysWhatIsBeingAuthorised() {
        let script = FanHelperLaunch.script(command: command)
        XCTAssertTrue(script.contains("ROOT"), script)
        XCTAssertTrue(script.contains("⌃C"), script)
    }

    /// The command is interpolated into a shell script, so a quote or a space in
    /// the path must not be able to end the argument and start something else.
    ///
    /// Asserted by RUNNING the one line that shows it — a `printf`, and nothing
    /// else from the script — and checking what a user would actually read. A
    /// hand-inspection of the quoting would be checking the escape against
    /// itself.
    func testTheDisplayedCommandSurvivesQuotesAndSpacesVerbatim() throws {
        for original in [command,
                         "sudo '/tmp/it'\\''s here/BetterStatsHelper'",
                         "sudo '/a b/BetterStatsHelper' --client '/a b/BetterStats.app'"] {
            let script = FanHelperLaunch.script(command: original)
            let line = try XCTUnwrap(script.split(separator: "\n")
                                           .first { $0.hasPrefix("printf") })
            XCTAssertEqual(try shell(String(line)).trimmingCharacters(in: .whitespacesAndNewlines),
                           original,
                           "the user would be shown something other than what runs")
        }
    }

    /// Runs one line of shell and returns its output. Deliberately only ever
    /// handed a `printf` — nothing in this suite executes the script's `exec`.
    private func shell(_ line: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", line]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// This project's own checkout path contains a space, so an unquoted command
    /// would be two arguments and the instruction would be wrong for exactly the
    /// person most likely to read it.
    func testTheStartCommandIsQuotedForAPathWithSpaces() {
        let command = FanControlPanel.startCommand()
        XCTAssertTrue(command.hasPrefix("sudo '"), command)
        XCTAssertEqual(FanControlPanel.quoted("/a b/c"), "'/a b/c'")
        XCTAssertEqual(FanControlPanel.quoted("/it's"), "'/it'\\''s'")
    }

    /// A script that runs `sudo` is written where only this user can reach it,
    /// and with its mode set at creation rather than afterwards — for the moment
    /// in between it would be writable at the process umask.
    func testTheScriptIsWrittenPrivateAndHandedToTerminal() throws {
        var opened: URL?
        let outcome = FanHelperLaunch.start(command: command, open: { opened = $0; return 0 })
        guard case .openedTerminal(let path) = outcome else {
            return XCTFail("\(outcome)")
        }
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertEqual(opened?.path, path)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]
                                 as? NSNumber)
        XCTAssertEqual(mode.int16Value, 0o700, "another user could read or run it")
        let written = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(written, FanHelperLaunch.script(command: command))
    }

    /// Terminal refusing to open must leave a sentence, not a half-state.
    func testATerminalThatWillNotOpenIsReportedRatherThanAssumed() {
        let outcome = FanHelperLaunch.start(command: command, open: { _ in 1 })
        guard case .failed(let why) = outcome else {
            return XCTFail("a failed launch was reported as a success")
        }
        XCTAssertFalse(why.isEmpty)
    }
}
