import XCTest
@testable import PowerKit

// Installing a root LaunchDaemon is the single most consequential thing this
// project can do to a machine, and it is the one thing the test suite cannot
// actually perform: running the installer to find out whether it works leaves a
// root daemon behind on a real Mac either way.
//
// So it is split. WHAT WOULD BE DONE is pure data — `FanDaemonInstall.plan` — and
// everything interesting about it is asserted here: which files, where, owned by
// whom, with which permissions, in which order, and what launchd is told. WHAT IS
// DONE is a small loop over that data with no decisions of its own, driven here
// by a recorder rather than by the filesystem.
//
// NOTHING HERE INSTALLS ANYTHING, elevates anything, or raises a dialog.

// ── The plan ────────────────────────────────────────────────────────────────

final class FanDaemonPlanTests: XCTestCase {

    private let bundledHelper =
        "/Users/someone/Applications/BetterStats.app/Contents/MacOS/BetterStatsHelper"

    private func plan(helper: String? = nil,
                      uid: uid_t = 501,
                      identifier: String? = FanDaemon.clientSigningIdentifier,
                      exists: Bool = true) -> Result<FanDaemonInstall.Plan,
                                                     FanDaemonInstall.Refusal> {
        FanDaemonInstall.plan(sourceHelper: helper ?? bundledHelper,
                              ownerUID: uid,
                              clientIdentifier: identifier,
                              fileExists: { _ in exists })
    }

    private func steps() throws -> [FanDaemonInstall.Step] {
        try plan().get().steps
    }

    /// Exactly two files land on the disk, and both of them are named in the
    /// uninstaller. A third would be an artifact nothing removes.
    func testItInstallsTwoFilesAndBothAreOnTheUninstallList() throws {
        let written = try steps().compactMap { step -> String? in
            switch step.action {
            case .copy, .write: return step.path
            default: return nil
            }
        }
        XCTAssertEqual(written, [FanDaemon.helperPath, FanDaemon.plistPath])

        let removed = FanHelperInstall.artifacts().all.map(\.path)
        for path in written {
            XCTAssertTrue(removed.contains(path),
                          "\(path) is installed and nothing removes it")
        }
    }

    /// The permissions are the security model here — Apple's own SMAppService
    /// header says a legacy LaunchDaemon is bootstrapped without approval
    /// "since writing to /Library is protected with filesystem permissions".
    /// If that is the check, these are the numbers that matter.
    func testEverythingInstalledIsRootOwnedAndNotUserWritable() throws {
        for step in try steps() {
            switch step.action {
            case .run: continue
            case .makeDirectory, .copy, .write:
                XCTAssertTrue(step.ownedByRoot, "\(step.path) would not be root's")
                XCTAssertTrue(step.path.hasPrefix("/Library/"),
                              "\(step.path) is not somewhere only root can write")
                XCTAssertEqual(step.mode & 0o022, 0,
                               "\(step.path) would be group- or world-writable")
            }
        }
    }

    func testTheHelperIsExecutableAndThePlistIsNot() throws {
        let modes = Dictionary(uniqueKeysWithValues: try steps().compactMap {
            step -> (String, mode_t)? in
            if case .run = step.action { return nil }
            return (step.path, step.mode)
        })
        XCTAssertEqual(modes[FanDaemon.helperPath], 0o755)
        XCTAssertEqual(modes[FanDaemon.plistPath], 0o644)
        XCTAssertEqual(modes[FanDaemon.helperDirectory], 0o755)
    }

    /// The directory has to exist before the copy into it, and the plist naming
    /// the helper must not be written before the helper is there — launchd
    /// retries a job whose program is missing, forever.
    func testTheOrderIsDirectoryThenBinaryThenPlistThenLaunchd() throws {
        let order = try steps().map { step -> String in
            switch step.action {
            case .makeDirectory:              return "mkdir \(step.path)"
            case .copy:                       return "copy \(step.path)"
            case .write:                      return "write \(step.path)"
            case .run(_, let args):           return "launchctl \(args.first ?? "")"
            }
        }
        XCTAssertEqual(order, ["mkdir \(FanDaemon.helperDirectory)",
                               "copy \(FanDaemon.helperPath)",
                               "write \(FanDaemon.plistPath)",
                               "launchctl bootout",
                               "launchctl bootstrap"])
    }

    /// Reinstalling over a running daemon has to replace it. launchd does not
    /// notice a rewritten plist on its own, so the old job is booted out first.
    func testAPreviousDaemonIsBootedOutBeforeTheNewOneIsLoaded() throws {
        let launchctl = try steps().compactMap { step -> [String]? in
            if case .run(let exe, let args) = step.action {
                XCTAssertEqual(exe, "/bin/launchctl")
                return args
            }
            return nil
        }
        XCTAssertEqual(launchctl, [["bootout", "system/\(FanDaemon.label)"],
                                   ["bootstrap", "system", FanDaemon.plistPath]])
    }

    /// THE ONE THAT MATTERS MOST. launchd must be pointed at the ROOT-OWNED COPY,
    /// never at the app bundle. An SMAppService daemon runs its program from
    /// inside the bundle; ~/Applications is writable by the user, so root
    /// executing from there hands root to anything that can write your home
    /// directory. Copying to /Library is the entire reason this route was chosen
    /// over SMAppService, and this assertion is that reason.
    func testLaunchdIsPointedAtTheRootOwnedCopyAndNeverAtTheAppBundle() throws {
        let arguments = try programArguments()
        XCTAssertEqual(arguments.first, FanDaemon.helperPath)
        for argument in arguments {
            XCTAssertFalse(argument.contains(".app/"),
                           "root would execute \(argument), which lives in a "
                         + "user-writable bundle")
        }
    }

    func testTheDaemonIsToldToServeTheInstallingUser() throws {
        XCTAssertEqual(try programArguments(),
                       [FanDaemon.helperPath, FanDaemon.serveArgument, "--uid", "501"])
        // And a different user gets a different plist, so two accounts cannot
        // silently share one install.
        let other = try FanDaemonInstall.plan(sourceHelper: bundledHelper, ownerUID: 502,
                                              clientIdentifier: FanDaemon.clientSigningIdentifier,
                                              fileExists: { _ in true }).get()
        XCTAssertNotEqual(other.steps, try steps())
    }

    /// THE JOB IS ON DEMAND. launchd holds the socket; nothing runs until the app
    /// connects. RunAtLoad and KeepAlive would each undo that on their own —
    /// RunAtLoad starts it at boot, KeepAlive restarts it the moment it idles out
    /// — so their ABSENCE is the feature and is asserted, not just the presence
    /// of `Sockets`.
    func testTheJobIsLaunchedOnDemandAndNotResident() throws {
        let plist = try decodedPlist()
        XCTAssertEqual(plist["Label"] as? String, FanDaemon.label)
        XCTAssertNil(plist["RunAtLoad"], "the daemon would start at boot and stay resident")
        XCTAssertNil(plist["KeepAlive"], "launchd would restart it every time it idled out")

        let sockets = try XCTUnwrap(plist["Sockets"] as? [String: Any],
                                    "no Sockets: launchd has nothing to listen on, so the "
                                  + "daemon can never be started by a connection")
        XCTAssertEqual(Array(sockets.keys), [FanDaemon.socketActivationName])
    }

    /// The socket launchd creates has to have the same owner and mode the helper
    /// used to set for itself. This is the whole reason on-demand was safe to
    /// adopt: it moves WHO creates the socket, not who may talk to it.
    func testLaunchdIsAskedForTheSameSocketTheHelperUsedToMake() throws {
        let plist = try decodedPlist()
        let sockets = try XCTUnwrap(plist["Sockets"] as? [String: Any])
        let entry = try XCTUnwrap(sockets[FanDaemon.socketActivationName] as? [String: Any])

        XCTAssertEqual(entry["SockPathName"] as? String, FanSocket.path)
        XCTAssertEqual(entry["SockPathOwner"] as? Int, 501,
                       "the socket must belong to the user being served, not to root")
        // 384 == 0o600. launchd.plist(5): "Property lists don't support octal,
        // so please convert the value to decimal." Asserted in decimal so a
        // change to octal-looking-but-wrong is caught.
        XCTAssertEqual(entry["SockPathMode"] as? Int, 384,
                       "the socket must be owner-only, as the session helper chmods it")
    }

    /// The plist and the code must agree on the socket's name, or the daemon
    /// starts and finds nothing to serve. Read out of the generated plist rather
    /// than restated, so there is one source of truth.
    func testTheActivationNameMatchesWhatTheHelperWillAskFor() throws {
        let plist = try decodedPlist()
        let sockets = try XCTUnwrap(plist["Sockets"] as? [String: Any])
        XCTAssertNotNil(sockets[FanDaemon.socketActivationName],
                        "FanDaemon.activatedSocket() asks launchd for "
                      + "\(FanDaemon.socketActivationName), which this plist does not offer")
    }

    /// No log files. A daemon that writes to StandardOutPath leaves a file the
    /// uninstaller does not know about and nothing rotates.
    func testTheJobLeavesNoLogFilesBehind() throws {
        let plist = try decodedPlist()
        XCTAssertNil(plist["StandardOutPath"])
        XCTAssertNil(plist["StandardErrorPath"])
    }

    func testThePlistIsRealXMLThatLaunchdCouldRead() throws {
        let data = try FanDaemonInstall.plist(ownerUID: 501)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).hasPrefix("<?xml"))
        XCTAssertNoThrow(try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil))
    }

    // ── What it refuses ─────────────────────────────────────────────────────

    /// A `swift build` binary has no bundle and is signed by the linker under an
    /// identifier like `BetterStatsHelper-3f2a…`, so a daemon installed from one
    /// would refuse the very app it was installed for. Caught here, where the
    /// message can say to run ./build-app.sh.
    func testABuildDirectoryBinaryIsRefused() {
        guard case .failure(let why) = plan(helper: "/Users/someone/proj/.build/debug/BetterStatsHelper")
        else { return XCTFail("an unbundled build was accepted") }
        XCTAssertEqual(why, .notInsideAnAppBundle("/Users/someone/proj/.build/debug/BetterStatsHelper"))
        XCTAssertTrue(why.localizedDescription.contains("build-app.sh"),
                      why.localizedDescription)
    }

    func testAMissingHelperIsRefusedBeforeAnythingElseIsChecked() {
        guard case .failure(let why) = plan(exists: false) else {
            return XCTFail("planned an install of a file that is not there")
        }
        XCTAssertEqual(why, .noSuchHelper(bundledHelper))
    }

    /// The daemon serves ONE ordinary user. Installed for root it would serve
    /// nobody, and it would do it silently.
    func testInstallingForRootIsRefused() {
        guard case .failure(let why) = plan(uid: 0) else {
            return XCTFail("planned a daemon that serves nobody")
        }
        XCTAssertEqual(why, .ownerWouldBeRoot)
    }

    /// The daemon accepts one signing identifier and it is compiled in. A bundle
    /// signing as something else would install perfectly and then refuse every
    /// connection — the worst kind of working, and worth one string compare.
    func testABundleThatSignsAsSomethingElseIsRefused() {
        for identifier in [nil, "com.example.other", ""] {
            guard case .failure(let why) = plan(identifier: identifier) else {
                return XCTFail("accepted a bundle signing as \(identifier ?? "nothing")")
            }
            XCTAssertEqual(why, .wrongSigningIdentifier(found: identifier))
            XCTAssertTrue(why.localizedDescription.contains(FanDaemon.clientSigningIdentifier),
                          why.localizedDescription)
        }
    }

    // ── helpers ─────────────────────────────────────────────────────────────

    private func programArguments() throws -> [String] {
        try XCTUnwrap(decodedPlist()["ProgramArguments"] as? [String])
    }

    private func decodedPlist() throws -> [String: Any] {
        let data = try steps().compactMap { step -> Data? in
            if case .write(let d) = step.action, step.path == FanDaemon.plistPath { return d }
            return nil
        }.first
        let plist = try PropertyListSerialization.propertyList(
            from: try XCTUnwrap(data), options: [], format: nil)
        return try XCTUnwrap(plist as? [String: Any])
    }
}

// ── Carrying the plan out ───────────────────────────────────────────────────

/// The installer, driven by something that records instead of doing. This is the
/// only way to assert the failure paths at all: "what happens when the chown
/// fails" cannot be answered by running a real install as root, because the
/// answer would be a real half-installed daemon.
final class FanDaemonPerformTests: XCTestCase {

    final class Recorder: FanDaemonInstall.Operations {
        enum Call: Equatable {
            case makeDirectory(String, mode_t)
            case copy(from: String, to: String, mode_t)
            case write(to: String, mode_t)
            case chownRoot(String)
            case run(String, [String])
        }
        private(set) var calls: [Call] = []
        /// Paths whose operation should fail.
        var failing: Set<String> = []
        var failingChown: Set<String> = []
        var exitStatus: [String: Int32] = [:]

        func makeDirectory(_ path: String, mode: mode_t) -> Bool {
            calls.append(.makeDirectory(path, mode))
            return !failing.contains(path)
        }
        func copyFile(from: String, to: String, mode: mode_t) -> Bool {
            calls.append(.copy(from: from, to: to, mode))
            return !failing.contains(to)
        }
        func writeFile(_ data: Data, to path: String, mode: mode_t) -> Bool {
            calls.append(.write(to: path, mode))
            return !failing.contains(path)
        }
        func setOwnerRoot(_ path: String) -> Bool {
            calls.append(.chownRoot(path))
            return !failingChown.contains(path)
        }
        func run(_ executable: String, _ arguments: [String]) -> Int32 {
            calls.append(.run(executable, arguments))
            return exitStatus[arguments.first ?? ""] ?? 0
        }
    }

    private func plan() throws -> FanDaemonInstall.Plan {
        try FanDaemonInstall.plan(
            sourceHelper: "/Users/someone/Applications/BetterStats.app/Contents/MacOS/BetterStatsHelper",
            ownerUID: 501,
            clientIdentifier: FanDaemon.clientSigningIdentifier,
            fileExists: { _ in true }).get()
    }

    func testAGoodInstallDoesEveryStepAndChownsEveryFile() throws {
        let ops = Recorder()
        let report = FanDaemonInstall.perform(try plan(), ops: ops)
        XCTAssertTrue(report.ok)
        XCTAssertEqual(ops.calls, [
            .makeDirectory(FanDaemon.helperDirectory, 0o755),
            .chownRoot(FanDaemon.helperDirectory),
            .copy(from: "/Users/someone/Applications/BetterStats.app/Contents/MacOS/BetterStatsHelper",
                  to: FanDaemon.helperPath, 0o755),
            .chownRoot(FanDaemon.helperPath),
            .write(to: FanDaemon.plistPath, 0o644),
            .chownRoot(FanDaemon.plistPath),
            .run("/bin/launchctl", ["bootout", "system/\(FanDaemon.label)"]),
            .run("/bin/launchctl", ["bootstrap", "system", FanDaemon.plistPath]),
        ])
    }

    /// THE FAILURE THAT MUST NOT BE SURVIVED. If the copied binary cannot be
    /// given to root it is still owned by whoever ran the install, and writing
    /// the plist next would tell launchd to run a user-writable file as root at
    /// every boot. That is a privilege escalation installed by the security fix.
    func testAFailedChownStopsEverythingBeforeThePlistIsWritten() throws {
        let ops = Recorder()
        ops.failingChown = [FanDaemon.helperPath]
        let report = FanDaemonInstall.perform(try plan(), ops: ops)
        XCTAssertFalse(report.ok)
        XCTAssertFalse(ops.calls.contains(.write(to: FanDaemon.plistPath, 0o644)),
                       "a plist was written naming a binary root does not own")
        XCTAssertFalse(ops.calls.contains(where: {
            if case .run = $0 { return true } else { return false }
        }), "launchd was told to load it anyway")
        XCTAssertEqual(report.outcomes.last?.path, FanDaemon.helperPath)
        XCTAssertFalse(report.outcomes.last?.ok ?? true)
    }

    func testAFailedCopyStopsBeforeThePlist() throws {
        let ops = Recorder()
        ops.failing = [FanDaemon.helperPath]
        let report = FanDaemonInstall.perform(try plan(), ops: ops)
        XCTAssertFalse(report.ok)
        XCTAssertFalse(ops.calls.contains(.write(to: FanDaemon.plistPath, 0o644)))
    }

    /// `bootout` fails whenever there was nothing loaded, which is every FIRST
    /// install. Treating that as an error would make the ordinary case report a
    /// failure.
    func testAFirstInstallIsNotFailedByAPointlessBootout() throws {
        let ops = Recorder()
        ops.exitStatus = ["bootout": 3]
        let report = FanDaemonInstall.perform(try plan(), ops: ops)
        XCTAssertTrue(report.ok)
        XCTAssertTrue(ops.calls.contains(.run("/bin/launchctl",
                                              ["bootstrap", "system", FanDaemon.plistPath])))
    }

    /// A failed bootstrap IS an error — the files are on the disk and nothing is
    /// running. Reported, and the files left where they are so a retry or an
    /// uninstall can find them.
    func testAFailedBootstrapIsReported() throws {
        let ops = Recorder()
        ops.exitStatus = ["bootstrap": 5]
        let report = FanDaemonInstall.perform(try plan(), ops: ops)
        XCTAssertFalse(report.ok)
        XCTAssertEqual(report.outcomes.last?.detail, "exit 5")
    }
}

// ── The pin, and why it survives a rebuild ──────────────────────────────────

/// The one behavioural difference between the session helper and the installed
/// daemon, and the reason the install button can exist at all.
final class FanClientPinTests: XCTestCase {

    private let identifier = FanDaemon.clientSigningIdentifier

    private func peer(_ cdhash: String?, _ id: String?, uid: uid_t = 501) -> FanPeer {
        FanPeer(euid: uid, cdhash: cdhash, signingIdentifier: id)
    }

    /// THE REBUILD. Same app, rebuilt, so a different cdhash and the same signing
    /// identifier. The session helper refuses it — correctly, it pinned one build
    /// — and the installed daemon accepts it, which is what stops the install
    /// button from being "reinstall after every build".
    func testARebuiltAppIsRefusedBySessionAndAcceptedByTheDaemon() {
        let before = peer("aaaa1111", identifier)
        let after = peer("bbbb2222", identifier)

        XCTAssertEqual(FanAccess.decide(peer: before, ownerUID: 501,
                                        pin: .exactBuild(cdhash: "aaaa1111")), .accept)
        guard case .refuse = FanAccess.decide(peer: after, ownerUID: 501,
                                              pin: .exactBuild(cdhash: "aaaa1111")) else {
            return XCTFail("the session helper stopped pinning one build")
        }
        XCTAssertEqual(FanAccess.decide(peer: after, ownerUID: 501,
                                        pin: .signingIdentifier(identifier)), .accept)
    }

    /// The kernel's answer still runs first and still decides. This is the check
    /// that does not weaken when the pin does, and it is the whole reason another
    /// user on the machine cannot use an install you paid for with your password.
    func testAnotherUserIsRefusedUnderEitherPin() {
        for pin: FanClientPin in [.exactBuild(cdhash: "aaaa1111"),
                                  .signingIdentifier(identifier)] {
            guard case .refuse(let why) = FanAccess.decide(
                peer: peer("aaaa1111", identifier, uid: 502), ownerUID: 501, pin: pin) else {
                return XCTFail("another user was accepted under \(pin)")
            }
            XCTAssertTrue(why.contains("502"), why)
        }
    }

    /// No valid signature is no identity, and no identity is a refusal — never a
    /// pass. Under the identifier pin this is the load-bearing half: an
    /// identifier read out of a signature that does not verify is a string in a
    /// file.
    func testAnUnsignedOrTamperedCallerIsRefusedByTheDaemonToo() {
        guard case .refuse(let why) = FanAccess.decide(
            peer: peer(nil, identifier), ownerUID: 501,
            pin: .signingIdentifier(identifier)) else {
            return XCTFail("a caller with no valid signature was accepted")
        }
        XCTAssertTrue(why.contains("signature"), why)
    }

    func testASignatureWithNoIdentifierIsRefused() {
        guard case .refuse = FanAccess.decide(peer: peer("aaaa1111", nil), ownerUID: 501,
                                              pin: .signingIdentifier(identifier)) else {
            return XCTFail("a caller with no identifier was accepted")
        }
    }

    func testADifferentIdentifierIsRefusedAndNamed() {
        guard case .refuse(let why) = FanAccess.decide(
            peer: peer("aaaa1111", "com.example.malware"), ownerUID: 501,
            pin: .signingIdentifier(identifier)) else {
            return XCTFail("a different program was accepted")
        }
        XCTAssertTrue(why.contains("com.example.malware"), why)
    }

    /// THE HONEST LIMIT, written as a test so it cannot quietly stop being true
    /// in the documentation while staying true in the code.
    ///
    /// The identifier is a string anyone can choose. Measured, not argued:
    ///
    ///     cc -o notmine t.c
    ///     codesign --force --sign - -i dev.noah.betterstats notmine
    ///     codesign -dvv notmine
    ///     Identifier=dev.noah.betterstats   Signature=adhoc   valid on disk
    ///
    /// So a program that is not BetterStats, signed ad-hoc under our identifier
    /// by anyone who can run codesign, IS ACCEPTED by the installed daemon. That
    /// is the price of an install that survives rebuilds without a Developer ID,
    /// it is stated in FanLink.swift, FanDaemon.swift, the helper's usage text
    /// and the install sheet, and it is asserted here so nobody can later claim
    /// the check is stronger than it is.
    func testAnyProgramSignedUnderOurIdentifierIsAcceptedByTheDaemon() {
        let impostor = peer("ffff9999", identifier)
        XCTAssertEqual(FanAccess.decide(peer: impostor, ownerUID: 501,
                                        pin: .signingIdentifier(identifier)),
                       .accept,
                       "if this ever refuses, the trust-model notes are now wrong")
        // And the session helper, which pins the build, still refuses it.
        guard case .refuse = FanAccess.decide(peer: impostor, ownerUID: 501,
                                              pin: .exactBuild(cdhash: "aaaa1111")) else {
            return XCTFail("the session helper is meant to be the stronger one")
        }
    }
}

// ── What the app can say about the install ──────────────────────────────────

final class FanDaemonStateTests: XCTestCase {

    func testNothingInstalledIsTheShippedState() {
        XCTAssertEqual(FanDaemon.state(installed: false, answered: false, helloVersion: nil),
                       .notInstalled)
        // Even if something is answering — a session helper is running — the
        // install state is about what is on the disk.
        XCTAssertEqual(FanDaemon.state(installed: false, answered: true, helloVersion: 1),
                       .notInstalled)
        XCTAssertTrue(FanDaemon.summary(.notInstalled).contains("not installed"))
    }

    func testInstalledAndAnsweringIsRunning() {
        XCTAssertEqual(FanDaemon.state(installed: true, answered: true,
                                       helloVersion: FanDaemon.protocolVersion),
                       .running)
    }

    /// launchd should have started it. Silence is a fault, not a state to wait
    /// in, and the strip says what to do about it.
    func testAnInstalledDaemonThatSaysNothingIsAFault() {
        XCTAssertEqual(FanDaemon.state(installed: true, answered: false, helloVersion: nil),
                       .installedButSilent)
        XCTAssertTrue(FanDaemon.summary(.installedButSilent).contains("not answering"))
    }

    /// The frozen-copy problem, which this design creates and therefore has to
    /// detect: the installed daemon is the build that was current at install
    /// time, and the app talking to it may be months newer.
    func testADaemonOlderThanTheAppIsNoticed() {
        XCTAssertEqual(FanDaemon.state(installed: true, answered: true,
                                       helloVersion: 1, appVersion: 2),
                       .installedButOlder(daemonVersion: 1))
        XCTAssertTrue(FanDaemon.summary(.installedButOlder(daemonVersion: 1))
                          .contains("older"))
    }

    /// A helper from before the version field existed answers with nil, and that
    /// is version 1 rather than "unknown, assume fine".
    func testAHelperWithNoVersionFieldCountsAsVersionOne() {
        XCTAssertEqual(FanDaemon.state(installed: true, answered: true,
                                       helloVersion: nil, appVersion: 2),
                       .installedButOlder(daemonVersion: 1))
    }

    /// A daemon NEWER than the app is left alone. That happens when an old build
    /// is launched beside a current install, and reinstalling from the old build
    /// would be a downgrade nobody asked for.
    func testANewerDaemonIsNotTreatedAsAProblem() {
        XCTAssertEqual(FanDaemon.state(installed: true, answered: true,
                                       helloVersion: 5, appVersion: 2), .running)
    }

    func testTheStripOffersInstallOrUninstallButNeverBoth() {
        XCTAssertEqual(FanDaemon.button(installed: false, bundled: true), .install)
        XCTAssertEqual(FanDaemon.button(installed: true, bundled: true), .uninstall)
        // A `swift build` binary can do neither: the install would be refused and
        // the uninstall names a bundled helper that is not there.
        XCTAssertEqual(FanDaemon.button(installed: false, bundled: false), .none)
        XCTAssertEqual(FanDaemon.button(installed: true, bundled: false), .none)
    }

    /// The daemon's label must not collide with the retired one — a machine may
    /// have both, and booting out the wrong job would leave the other loaded.
    func testTheDaemonLabelIsDistinctFromTheRetiredOne() {
        XCTAssertNotEqual(FanDaemon.label, FanHelperInstall.retiredDaemonLabel)
        XCTAssertEqual(FanHelperInstall.daemonLabels,
                       [FanHelperInstall.retiredDaemonLabel, FanDaemon.label])
    }
}

// ── The one authorisation ───────────────────────────────────────────────────

/// The command that is about to run as root, as text. Every one of these
/// assertions is about a string that will be handed to a shell with root
/// privileges, which is why the quoting is tested rather than eyeballed — and
/// this project's own checkout path contains a space.
final class FanElevationTests: XCTestCase {

    func testAPathWithSpacesSurvivesAsOneArgument() {
        let command = FanElevation.installCommand(
            helper: "/Users/n/Downloads/better stats app/BetterStats.app/Contents/MacOS/BetterStatsHelper",
            ownerUID: 501)
        XCTAssertTrue(command.hasPrefix("'/Users/n/Downloads/better stats app/"), command)
        XCTAssertTrue(command.hasSuffix("' --install --uid 501"), command)
    }

    /// `do shell script … with administrator privileges` does NOT go through
    /// sudo and does not set $SUDO_UID, which the helper otherwise falls back to.
    /// Without this the button's install refuses with "cannot tell which user to
    /// install for" — found in review, not in the field.
    func testTheInstallCommandNamesTheUserBecauseTheDialogWillNot() {
        XCTAssertTrue(FanElevation.installCommand(helper: "/x/H", ownerUID: 502)
                          .contains("--uid 502"))
    }

    /// An apostrophe in a path ends a single-quoted string. `'\''` is the only
    /// correct way to put one back, and getting it wrong here means running a
    /// different command as root than the one that was displayed.
    func testAnApostropheInThePathCannotEndTheQuoting() {
        let quoted = FanElevation.shellQuoted("/Users/noah's mac/BetterStats.app")
        XCTAssertEqual(quoted, "'/Users/noah'\\''s mac/BetterStats.app'")
    }

    /// The same string then goes inside an AppleScript literal, where `"` and `\`
    /// are what matter.
    func testAppleScriptQuotingEscapesQuotesAndBackslashes() {
        XCTAssertEqual(FanElevation.appleScriptQuoted(#"a"b\c"#), #""a\"b\\c""#)
    }

    /// The script is one statement: the command, a prompt, and the request for
    /// privileges. Both parameters are documented in this machine's own
    /// StandardAdditions.sdef.
    func testTheScriptAsksForAdministratorPrivilegesWithOurOwnPrompt() {
        let script = FanElevation.script(command: "/bin/echo hi", prompt: "because")
        XCTAssertEqual(script,
                       "do shell script \"/bin/echo hi\" with prompt \"because\" "
                     + "with administrator privileges")
        XCTAssertEqual(FanElevation.osascriptArguments(command: "/bin/echo hi",
                                                       prompt: "because"),
                       ["-e", script])
    }

    /// The objection to a password box is that it names nothing. This one names
    /// both files it is about to create.
    func testThePromptNamesEveryPathTheInstallWillCreate() {
        XCTAssertTrue(FanElevation.installPrompt.contains(FanDaemon.helperPath))
        XCTAssertTrue(FanElevation.installPrompt.contains(FanDaemon.plistPath))
        XCTAssertTrue(FanElevation.uninstallPrompt.lowercased().contains("fans"))
    }

    /// A refused authorisation is an answer, not a failure. Reporting Cancel as
    /// an error is how an app teaches people to press the other button.
    func testCancellingIsNotAnError() {
        XCTAssertEqual(FanElevation.classify(status: 1, output: "",
                                             error: "execution error: User canceled. (-128)"),
                       .cancelled)
        XCTAssertEqual(FanElevation.classify(status: 0, output: "done", error: ""),
                       .done("done"))
        guard case .failed(let why) = FanElevation.classify(
            status: 1, output: "", error: "something else went wrong") else {
            return XCTFail("a real failure was swallowed")
        }
        XCTAssertEqual(why, "something else went wrong")
    }

    /// The install command shown in the sheet and the one the button runs are the
    /// same string, so a user who would rather type it themselves is typing what
    /// the button does rather than an approximation of it.
    func testTheUninstallCommandIsTheHelpersOwnUninstall() {
        XCTAssertEqual(FanElevation.uninstallCommand(helper: "/x/H"), "'/x/H' --uninstall")
        XCTAssertEqual(FanElevation.installCommand(helper: "/x/H", ownerUID: 501),
                       "'/x/H' --install --uid 501")
    }
}
