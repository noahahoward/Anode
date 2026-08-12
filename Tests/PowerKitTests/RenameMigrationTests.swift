import AppKit
import XCTest
@testable import AnodeApp
@testable import PowerKit

/// Carrying a machine's history and settings across the rename from BetterStats
/// to Anode.
///
/// Worth testing because both migrations run ONCE, early, and silently — the
/// failure mode is not a crash but a user opening the app to find their
/// preferences reset and a week of history gone, with nothing on screen to say
/// why.
final class RenameMigrationTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("anode-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ path: String, _ body: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    // ── The store ───────────────────────────────────────────────────────────

    /// The history moves to the new name rather than being abandoned beside it.
    func testTheHistoryIsAdoptedUnderTheNewName() throws {
        try write("BetterStats/history.sqlite", "old")
        HistoryStore.adoptPreviousName(
            at: root.appendingPathComponent("Anode/history.sqlite"), under: root)
        XCTAssertTrue(exists("Anode/history.sqlite"), "a week of history was left behind")
        XCTAssertFalse(exists("BetterStats/history.sqlite"),
                       "moved, not copied — this store runs to hundreds of megabytes")
    }

    /// SQLITE'S SIDECARS COME TOO. A `-wal` holds committed transactions that are
    /// not yet in the main file, so moving the database alone silently drops the
    /// most recent writes — the exact rows anyone would look for first.
    func testTheWriteAheadLogComesWithIt() throws {
        try write("BetterStats/history.sqlite", "db")
        try write("BetterStats/history.sqlite-wal", "recent writes")
        try write("BetterStats/history.sqlite-shm", "shm")
        HistoryStore.adoptPreviousName(
            at: root.appendingPathComponent("Anode/history.sqlite"), under: root)
        XCTAssertTrue(exists("Anode/history.sqlite-wal"),
                      "the most recent measurements were dropped")
        XCTAssertTrue(exists("Anode/history.sqlite-shm"))
    }

    /// Everything else in that directory moves as well — the discharge trend is
    /// the one that matters, since losing it makes the estimate start over.
    func testTheRestOfTheDirectoryComesToo() throws {
        try write("BetterStats/history.sqlite", "db")
        try write("BetterStats/discharge-trend.json", "{}")
        HistoryStore.adoptPreviousName(
            at: root.appendingPathComponent("Anode/history.sqlite"), under: root)
        XCTAssertTrue(exists("Anode/discharge-trend.json"))
    }

    /// It NEVER overwrites history recorded since the rename, so running twice is
    /// harmless and a stale old store cannot clobber a live one.
    func testItWillNotOverwriteHistoryRecordedSinceTheRename() throws {
        try write("BetterStats/history.sqlite", "old")
        try write("Anode/history.sqlite", "new")
        HistoryStore.adoptPreviousName(
            at: root.appendingPathComponent("Anode/history.sqlite"), under: root)
        let kept = try String(contentsOf: root.appendingPathComponent("Anode/history.sqlite"))
        XCTAssertEqual(kept, "new", "the current store was overwritten by an old one")
        XCTAssertTrue(exists("BetterStats/history.sqlite"), "and the old one was consumed anyway")
    }

    /// A machine that never ran the old build is untouched.
    func testAFreshMachineIsLeftAlone() {
        HistoryStore.adoptPreviousName(
            at: root.appendingPathComponent("Anode/history.sqlite"), under: root)
        XCTAssertFalse(exists("Anode/history.sqlite"),
                       "an empty store was created where none was needed")
    }

    // ── The settings ────────────────────────────────────────────────────────

    /// Preferences carry across, and are COPIED — a move would make going back to
    /// the old build a data loss, and a rename is exactly what people revert.
    func testSettingsAreCopiedFromThePreviousDomain() throws {
        // A SOURCE OF OUR OWN, never the real `com.betterstats.settings`. The
        // first version of this test wrote to that domain and cleared it in its
        // teardown, which wiped a live machine's preferences — a migration test is
        // the one most likely to reach for a production domain, because the domain
        // name is the thing under test.
        let (old, oldName) = try TestDefaults.make(owner: "RenameMigrationSource")
        defer { TestDefaults.destroy(old, oldName) }
        // The OLD prefix, which is the whole point: the rename moved the key
        // namespace as well as the domain, so a verbatim copy lands under names
        // the app no longer reads.
        old.set(true, forKey: "betterstats.startInMenuBarOnly")
        old.set(9.5, forKey: "betterstats.sampleInterval")

        let (fresh, name) = try TestDefaults.make(owner: "RenameMigration")
        defer { TestDefaults.destroy(fresh, name) }
        Settings.migrateFromPreviousName(into: fresh, from: oldName)

        XCTAssertEqual(fresh.bool(forKey: "anode.startInMenuBarOnly"), true)
        XCTAssertEqual(fresh.double(forKey: "anode.sampleInterval"), 9.5)
        XCTAssertNotNil(UserDefaults(suiteName: oldName)?
            .object(forKey: "betterstats.sampleInterval"),
            "the old domain was consumed, so reverting would lose these")
    }

    /// And it never runs over a domain that already has something in it, so a
    /// preference changed since the rename cannot be reverted by an old copy.
    func testItWillNotOverwriteSettingsChangedSinceTheRename() throws {
        let (old, oldName) = try TestDefaults.make(owner: "RenameMigrationSource")
        defer { TestDefaults.destroy(old, oldName) }
        old.set(1.0, forKey: "betterstats.sampleInterval")

        let (fresh, name) = try TestDefaults.make(owner: "RenameMigration")
        defer { TestDefaults.destroy(fresh, name) }
        fresh.set(7.0, forKey: "anode.sampleInterval")
        Settings.migrateFromPreviousName(into: fresh, from: oldName)
        XCTAssertEqual(fresh.double(forKey: "anode.sampleInterval"), 7.0,
                       "a setting changed since the rename was overwritten")
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// The one thing the rename CANNOT migrate.
final class OrphanedDaemonTests: XCTestCase {

    /// Every old label differs from the current one, which is the whole reason an
    /// old install goes unseen — and the reason each has to be looked for by name.
    func testEveryOldDaemonLabelDiffersFromTheCurrentOne() {
        for old in FanDaemon.previousLabels {
            XCTAssertNotEqual(FanDaemon.label, old)
        }
        XCTAssertTrue(FanDaemon.label.contains("anode"))
    }

    /// Both renames are remembered, not just the most recent.
    ///
    /// This is the case a single `previousLabel` got wrong: rename twice and the
    /// first old daemon stops being looked for, silently, on exactly the machines
    /// that have been running this longest.
    func testBothRenamesAreStillLookedFor() {
        XCTAssertTrue(FanDaemon.previousLabels.contains { $0.contains("betterstats") },
                      "the pre-rename daemon is no longer detected")
        XCTAssertTrue(FanDaemon.previousLabels.contains { $0.contains("noah") },
                      "the pre-identifier-change daemon is no longer detected")
        XCTAssertEqual(Set(FanDaemon.previousLabels).count, FanDaemon.previousLabels.count,
                       "a label is listed twice")
    }

    /// The same, for the login agent — which CAN clean up after itself, because
    /// its plist is the user's own.
    func testTheLoginAgentRemembersItsOldLabelsToo() {
        for old in LoginAgent.previousLabels {
            XCTAssertNotEqual(LoginAgent.label, old)
        }
        XCTAssertTrue(LoginAgent.previousLabels.contains { $0.contains("betterstats") })
        XCTAssertTrue(LoginAgent.previousLabels.contains { $0.contains("noah") })
    }

    /// The uninstall command names BOTH root-owned paths.
    ///
    /// Removing only the plist leaves the binary in `PrivilegedHelperTools`, and
    /// removing only the binary leaves launchd with a job it cannot start. A
    /// half-uninstall is worse than none, because it looks finished.
    func testTheUninstallCommandRemovesEverythingItInstalled() {
        // Asked about specific labels, NOT about this machine — the command has
        // to read the same on a machine with no old daemon on it.
        let label = FanDaemon.previousLabels[0]
        let command = FanDaemon.uninstallCommand(for: [label])
        XCTAssertTrue(command.contains("/Library/LaunchDaemons/\(label).plist"))
        XCTAssertTrue(command.contains(
            "/Library/PrivilegedHelperTools/\(label)"))
        // And unloads it first: deleting a plist under a running job leaves the
        // job running with nothing on disk describing it.
        XCTAssertTrue(command.contains("bootout"),
                      "the job is deleted from disk while still loaded")
        XCTAssertLessThan(command.range(of: "bootout")!.lowerBound,
                          command.range(of: "rm -f")!.lowerBound,
                          "it removes the files before unloading the job")
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// Where the orphan warning has to appear.
final class OrphanNoticePlacementTests: XCTestCase {

    /// It must be shown in the states that OFFER TO INSTALL, which is the whole
    /// point of noticing.
    ///
    /// The first version put it in a branch reached only when the new daemon is
    /// already installed — the one machine that does not need telling. On a
    /// machine with an old daemon and no new one, the app just asked to install,
    /// with no sign it had seen anything. Reported exactly that way.
    ///
    /// Asserted against the source rather than a rendered panel: the claim is
    /// about which branch carries it, and the states are a switch over a mode
    /// that needs a live helper connection to reach.
    func testTheWarningIsWiredIntoTheStatesThatOfferToInstall() throws {
        let source = try String(contentsOfFile: FileManager.default.currentDirectoryPath
            + "/Sources/AnodeApp/FanControlPanel.swift")
        // The `.off` state — a machine that has never turned fan control on.
        //
        // Bounded by the NEXT case rather than by a character count. It was the
        // first 900 characters, which is a stand-in for "this branch" that stops
        // being one the moment the branch grows — it broke on a comment being
        // added above the line it was looking for, which says nothing about
        // whether the warning is still wired in.
        let offState = try XCTUnwrap(source.range(of: "case .off:"))
        let rest = source[offState.upperBound...]
        let nextCase = rest.range(of: "\n        case ")?.lowerBound ?? rest.endIndex
        let offBranch = String(rest[..<nextCase])
        XCTAssertTrue(offBranch.contains("orphanNote"),
                      "the state that offers the install does not mention the old daemon")
        // And the one that leads to starting a helper by hand.
        XCTAssertTrue(source.contains("FanDaemon.orphanNote ?? Self.startCommand()"),
                      "the start-by-hand hint does not mention the old daemon")
    }
}

/// Nothing installs a root daemon because a user touched a control.
///
/// Reported as: you do not know the process, you drag what looks like a volume
/// slider, and a Terminal window opens.
///
/// The first fix hid the knob and left the bar as a reading. It did not work —
/// the cell subclass that was supposed to skip drawing the knob was never used,
/// so the knob stayed and only a source-text test said otherwise. The second is
/// simpler and has nothing to silently not-happen: with no helper there is no
/// control surface at all. The fan speeds are reported above this strip either
/// way, so nothing readable was lost with them.
final class InstallIsDeliberateTests: XCTestCase {

    private let fans = [
        FanInfo(index: 0, currentRPM: 2318, minRPM: 2317, maxRPM: 7826, targetRPM: nil),
        FanInfo(index: 1, currentRPM: 2500, minRPM: 2317, maxRPM: 7826, targetRPM: nil),
    ]

    /// The behavioural assertion, and the one that would have caught the first
    /// attempt: COUNT the controls rather than reading the code meant to remove
    /// them. This runs on a machine with no helper installed — which is every
    /// machine running the suite, since installing one needs root.
    func testThereIsNoControlSurfaceWithoutTheHelper() throws {
        try XCTSkipIf(FanDaemon.isInstalled(),
                      "this machine has the helper installed; the state under test is the other one")
        let panel = FanControlPanel(frame: NSRect(x: 0, y: 0, width: 420, height: 200))
        panel.update(fans: fans)
        XCTAssertEqual(panel.controlRowCount, 0,
                       "the fan control interface is on screen with no helper behind it")
    }

    /// And the guard behind it: every gesture route funnels through `gesture(_:)`,
    /// so it belongs there once rather than on each control, where a control
    /// added later would quietly reopen the road.
    func testGesturesDoNothingWithoutTheHelperInstalled() throws {
        let source = try String(contentsOfFile: FileManager.default.currentDirectoryPath
            + "/Sources/AnodeApp/FanControlPanel.swift")
        let fn = try XCTUnwrap(source.range(of: "private func gesture(_ g: FanSession.Gesture) {"))
        let body = String(source[fn.upperBound...].prefix(600))
        XCTAssertTrue(body.contains("guard installed else"),
                      "a gesture can still reach the install path")
    }
}
