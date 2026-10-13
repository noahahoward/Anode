import XCTest
@testable import PowerKit

/// When the app may replace itself without being asked each time.
final class AutoUpdateTests: XCTestCase {

    // ── Decision ────────────────────────────────────────────────────────────

    private func decide(enabled: Bool = true, _ state: SourceCheckout.State,
                        upstream: String? = "abc1234", failed: String? = nil)
        -> AutoUpdate.Decision {
        AutoUpdate.decision(enabled: enabled, state: state,
                            upstreamCommit: upstream, failedCommit: failed)
    }

    func testBehindUpdatesWhenTheSettingIsOn() {
        XCTAssertEqual(decide(.behind(commits: 2)), .update)
    }

    /// Off is today's behaviour exactly: nothing happens that the user did not
    /// press a button for.
    func testNothingUpdatesWhenTheSettingIsOff() {
        XCTAssertEqual(decide(enabled: false, .behind(commits: 2)), .openWindow)
    }

    /// Every state `update.sh` would refuse, or have nothing to do in, opens the
    /// window. A dirty checkout matters most: that is someone's work in progress.
    func testOnlyBehindUpdates() {
        for s: SourceCheckout.State in [.missing, .notARepository, .detached,
                                        .dirty(changed: 1), .noUpstream, .upToDate] {
            XCTAssertEqual(decide(s), .openWindow, "\(s)")
        }
    }

    /// A push that does not build is tried once, not at every launch.
    func testACommitThatFailedIsNotRetried() {
        XCTAssertEqual(decide(.behind(commits: 1), upstream: "abc1234", failed: "abc1234"),
                       .openWindow)
    }

    func testTheNextCommitAfterAFailureIsTried() {
        XCTAssertEqual(decide(.behind(commits: 2), upstream: "def5678", failed: "abc1234"),
                       .update)
    }

    /// An unknown upstream hash must not match a remembered empty one.
    func testAnEmptyFailureRecordBlocksNothing() {
        XCTAssertEqual(decide(.behind(commits: 1), upstream: nil, failed: nil), .update)
        XCTAssertEqual(decide(.behind(commits: 1), upstream: "", failed: ""), .update)
    }

    // ── Consent ─────────────────────────────────────────────────────────────

    /// The check runs before any window is up, which is where a consent prompt
    /// strands the app — so a gated folder is not read until it is known to work.
    func testAGatedCheckoutIsNotReadUnaskedUntilConfirmed() {
        let path = NSHomeDirectory() + "/Downloads/Anode"
        XCTAssertFalse(AutoUpdate.mayCheckUnasked(path: path, confirmedPath: nil))
        XCTAssertFalse(AutoUpdate.mayCheckUnasked(path: path, confirmedPath: "/elsewhere"))
        XCTAssertTrue(AutoUpdate.mayCheckUnasked(path: path, confirmedPath: path))
    }

    func testAnUngatedCheckoutNeedsNoConfirmation() {
        XCTAssertTrue(AutoUpdate.mayCheckUnasked(path: NSHomeDirectory() + "/Developer/Anode",
                                                 confirmedPath: nil))
    }

    /// The protected folder itself, not only things inside it.
    func testACheckoutThatIsTheGatedFolderItself() {
        XCTAssertFalse(AutoUpdate.mayCheckUnasked(path: NSHomeDirectory() + "/Documents",
                                                  confirmedPath: nil))
    }

    /// A denied prompt makes git fail, and that must not count as permission.
    func testOnlyAReadableCheckoutConfirmsAccess() {
        XCTAssertFalse(AutoUpdate.confirmsAccess(.missing))
        XCTAssertFalse(AutoUpdate.confirmsAccess(.notARepository))
        for s: SourceCheckout.State in [.detached, .dirty(changed: 3), .noUpstream,
                                        .upToDate, .behind(commits: 1)] {
            XCTAssertTrue(AutoUpdate.confirmsAccess(s), "\(s)")
        }
    }

    // ── Progress ────────────────────────────────────────────────────────────

    private func progress(_ lines: [String]) -> AutoUpdate.Progress {
        var p = AutoUpdate.Progress()
        lines.forEach { p.consume(line: $0) }
        return p
    }

    func testStartsAtZero() {
        let p = AutoUpdate.Progress()
        XCTAssertEqual(p.stage, .starting)
        XCTAssertEqual(p.fraction, 0)
    }

    /// The lines `update.sh` and `build-app.sh` print today, in order.
    func testFollowsTheScriptsOwnStages() {
        var p = AutoUpdate.Progress()
        let expected: [(String, AutoUpdate.Progress.Stage)] = [
            ("› fetching…", .fetching),
            ("› updated 0ae5b27 → 4222354:", .fetching),
            ("› building (release)…", .building),
            ("› assembling Anode.app…", .assembling),
            ("› compiling icon…", .assembling),
            ("› installed: /Users/me/Applications/Anode.app", .installing),
            ("› launching…", .relaunching),
        ]
        var last = -1.0
        for (line, stage) in expected {
            p.consume(line: line)
            XCTAssertEqual(p.stage, stage, line)
            if let f = p.fraction {
                XCTAssertGreaterThanOrEqual(f, last, line)
                last = f
            }
        }
        XCTAssertEqual(p.fraction, 1)
    }

    /// Nothing to measure between "building" and the first compiler step.
    func testTheBuildIsIndeterminateUntilAStepIsReported() {
        XCTAssertNil(progress(["› fetching…", "› building (release)…"]).fraction)
        XCTAssertNil(progress(["› building (release)…", "[0/1] Planning build",
                               "Building for production..."]).fraction)
    }

    func testBuildStepsMoveTheBarWithinTheBuildsShare() throws {
        let half = try XCTUnwrap(progress(["› building (release)…",
                                           "[40/80] Compiling PowerKit Battery.swift"]).fraction)
        let r = AutoUpdate.Progress.buildRange
        XCTAssertEqual(half, (r.lowerBound + r.upperBound) / 2, accuracy: 1e-9)
        let done = try XCTUnwrap(progress(["› building (release)…", "[80/80] Linking"]).fraction)
        XCTAssertEqual(done, r.upperBound, accuracy: 1e-9)
    }

    /// What `swift build` actually wrote to the log of a real automatic update:
    /// spaces inside the brackets, and a module name rather than "Compiling".
    func testReadsTheStepFormatSwiftBuildUsesOffATerminal() throws {
        let p = progress(["› building (release)…", "Building for production...",
                          "[1 / 7]", "[2 / 6] PowerKit", "[4 / 7] PowerKit"])
        let r = AutoUpdate.Progress.buildRange
        XCTAssertEqual(try XCTUnwrap(p.fraction),
                       r.lowerBound + (r.upperBound - r.lowerBound) * 4 / 7, accuracy: 1e-9)
    }

    /// `build-app.sh` runs `swift build` twice — the app, then the helper — and
    /// the second count starts again from the bottom.
    func testASecondBuildDoesNotMoveTheBarBackwards() throws {
        let p = progress(["› building (release)…", "[70/80] Compiling", "[1/6] Compiling"])
        let r = AutoUpdate.Progress.buildRange
        XCTAssertEqual(try XCTUnwrap(p.fraction),
                       r.lowerBound + (r.upperBound - r.lowerBound) * 70 / 80, accuracy: 1e-9)
    }

    /// A bracketed line in git's output is not a compiler step.
    func testStepsAreOnlyReadWhileBuilding() {
        XCTAssertEqual(progress(["› fetching…", "[3/4] something"]).fraction, 0.03)
    }

    func testAStageNeverGoesBackwards() {
        let p = progress(["› installed: /x/Anode.app", "› building (release)…"])
        XCTAssertEqual(p.stage, .installing)
    }

    func testUnrecognisedLinesChangeNothing() {
        let before = progress(["› fetching…"])
        var after = before
        for line in ["", "warning: unused variable", "[x/y] nope", "[5/3] backwards",
                     "›   4222354 Stop the table scrolling sideways", "[", "]"] {
            after.consume(line: line)
        }
        XCTAssertEqual(after, before)
    }

    // ── Settings ────────────────────────────────────────────────────────────

    /// Off until someone says otherwise, and not yet asked.
    func testAutoUpdateIsOffAndUnaskedOnAFreshMachine() throws {
        let (defaults, name) = try TestDefaults.make(owner: "AutoUpdate", test: self.name)
        defer { TestDefaults.destroy(defaults, name) }
        let s = Settings(defaults: defaults)
        XCTAssertFalse(s.autoUpdateEnabled)
        XCTAssertFalse(s.autoUpdatePromptSeen)
        XCTAssertNil(s.autoUpdateFailedCommit)
        XCTAssertNil(s.autoUpdateConfirmedPath)
    }

    func testAutoUpdateSettingsPersist() throws {
        let (defaults, name) = try TestDefaults.make(owner: "AutoUpdate", test: self.name)
        defer { TestDefaults.destroy(defaults, name) }
        let s = Settings(defaults: defaults)
        s.autoUpdateEnabled = true
        s.autoUpdatePromptSeen = true
        s.autoUpdateFailedCommit = "abc1234"
        s.autoUpdateConfirmedPath = "/Users/me/Downloads/Anode"
        let again = Settings(defaults: defaults)
        XCTAssertTrue(again.autoUpdateEnabled)
        XCTAssertTrue(again.autoUpdatePromptSeen)
        XCTAssertEqual(again.autoUpdateFailedCommit, "abc1234")
        XCTAssertEqual(again.autoUpdateConfirmedPath, "/Users/me/Downloads/Anode")
        s.autoUpdateFailedCommit = nil
        XCTAssertNil(Settings(defaults: defaults).autoUpdateFailedCommit)
    }

    /// The checkbox in Preferences redraws from an observer.
    func testTurningAutoUpdateOnNotifies() throws {
        let (defaults, name) = try TestDefaults.make(owner: "AutoUpdate", test: self.name)
        defer { TestDefaults.destroy(defaults, name) }
        let s = Settings(defaults: defaults)
        var fired = 0
        let token = s.observe(Settings.Key.autoUpdateEnabled) { fired += 1 }
        s.autoUpdateEnabled = true
        XCTAssertEqual(fired, 1)
        _ = token
    }
}
