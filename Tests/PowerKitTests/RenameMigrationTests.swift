import XCTest
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

    /// The two labels differ, which is the whole reason an old install goes
    /// unseen — and the reason it has to be looked for by name.
    func testTheOldDaemonHasADifferentLabel() {
        XCTAssertNotEqual(FanDaemon.label, FanDaemon.previousLabel)
        XCTAssertTrue(FanDaemon.previousLabel.contains("betterstats"))
        XCTAssertTrue(FanDaemon.label.contains("anode"))
    }

    /// The uninstall command names BOTH root-owned paths.
    ///
    /// Removing only the plist leaves the binary in `PrivilegedHelperTools`, and
    /// removing only the binary leaves launchd with a job it cannot start. A
    /// half-uninstall is worse than none, because it looks finished.
    func testTheUninstallCommandRemovesEverythingItInstalled() {
        let command = FanDaemon.previousUninstallCommand
        XCTAssertTrue(command.contains("/Library/LaunchDaemons/\(FanDaemon.previousLabel).plist"))
        XCTAssertTrue(command.contains(
            "/Library/PrivilegedHelperTools/\(FanDaemon.previousLabel)"))
        // And unloads it first: deleting a plist under a running job leaves the
        // job running with nothing on disk describing it.
        XCTAssertTrue(command.contains("bootout"),
                      "the job is deleted from disk while still loaded")
        XCTAssertLessThan(command.range(of: "bootout")!.lowerBound,
                          command.range(of: "rm -f")!.lowerBound,
                          "it removes the files before unloading the job")
    }
}
