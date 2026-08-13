import XCTest
@testable import PowerKit

/// Update-availability, tested against REAL git repositories built in a temp
/// directory rather than against canned strings.
///
/// The states here are all about the shape of a working copy — detached HEAD,
/// dirty tree, no upstream — and those are exactly the things a hand-written
/// fixture gets subtly wrong. A repo costs milliseconds to create and exercises
/// the actual arguments, so the test tells us the command is right and not just
/// that the parser is.
///
/// No network: the "remote" is another directory on disk, which is all `git
/// fetch` needs and is what makes this runnable on a plane.
final class SourceCheckoutTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(Self.gitIsAvailable, "git not on PATH")
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("anode-checkout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // ── Helpers ─────────────────────────────────────────────────────────────

    private static var gitIsAvailable: Bool { shell(["git", "--version"], in: nil) != nil }

    @discardableResult
    private static func shell(_ args: [String], in dir: URL?) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        if let dir { p.currentDirectoryURL = dir }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private func git(_ args: [String], in dir: URL) -> String? {
        Self.shell(["git"] + args, in: dir)
    }

    /// A repo with one commit. Identity is set locally so the test does not
    /// depend on — or touch — the machine's git config.
    private func makeRepo(_ name: String) throws -> URL {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        git(["init", "--initial-branch=main"], in: dir)
        git(["config", "user.email", "test@example.com"], in: dir)
        git(["config", "user.name", "Test"], in: dir)
        try "one\n".write(to: dir.appendingPathComponent("f.txt"), atomically: true,
                          encoding: .utf8)
        git(["add", "."], in: dir)
        git(["commit", "-m", "first"], in: dir)
        return dir
    }

    private func checkout(_ dir: URL) -> SourceCheckout { .atPath(dir.path) }

    // ── The states ──────────────────────────────────────────────────────────

    func testAPathThatIsNotARepository() throws {
        let plain = root.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        XCTAssertEqual(checkout(plain).state(), .notARepository)
    }

    /// A clone with nothing new upstream.
    func testUpToDate() throws {
        let origin = try makeRepo("origin")
        let clone = root.appendingPathComponent("clone")
        Self.shell(["git", "clone", "--quiet", origin.path, clone.path], in: root)
        Self.shell(["git", "config", "user.email", "test@example.com"], in: clone)
        Self.shell(["git", "config", "user.name", "Test"], in: clone)
        XCTAssertEqual(checkout(clone).state(), .upToDate)
    }

    /// The state the button exists for.
    func testBehindCountsCommits() throws {
        let origin = try makeRepo("origin")
        let clone = root.appendingPathComponent("clone")
        Self.shell(["git", "clone", "--quiet", origin.path, clone.path], in: root)

        for i in 2...4 {
            try "\(i)\n".write(to: origin.appendingPathComponent("f.txt"),
                               atomically: true, encoding: .utf8)
            git(["commit", "-am", "c\(i)"], in: origin)
        }
        let c = checkout(clone)
        XCTAssertTrue(c.fetch(), "fetch from a local origin should work")
        XCTAssertEqual(c.state(), .behind(commits: 3))
        XCTAssertTrue(c.state().isUpdatable)
    }

    /// Uncommitted work must stop the button, because `pull --ff-only` would
    /// refuse and stashing someone's changes is not an update's business.
    func testDirtyTreeBlocksUpdating() throws {
        let repo = try makeRepo("dirty")
        try "changed\n".write(to: repo.appendingPathComponent("f.txt"),
                              atomically: true, encoding: .utf8)
        XCTAssertEqual(checkout(repo).state(), .dirty(changed: 1))
        XCTAssertFalse(checkout(repo).state().isUpdatable)
    }

    /// UNTRACKED files must NOT block it. Every checkout that has been built in
    /// has `.build/` and a stray bundle lying around; treating those as "your
    /// work" would leave the button permanently disabled.
    func testUntrackedFilesDoNotBlockUpdating() throws {
        let origin = try makeRepo("origin")
        let clone = root.appendingPathComponent("clone")
        Self.shell(["git", "clone", "--quiet", origin.path, clone.path], in: root)
        try "build junk\n".write(to: clone.appendingPathComponent("untracked.o"),
                                 atomically: true, encoding: .utf8)
        XCTAssertEqual(checkout(clone).state(), .upToDate,
                       "an untracked build artefact was treated as uncommitted work")
    }

    func testDetachedHeadIsNotUpdatable() throws {
        let repo = try makeRepo("detached")
        let head = try XCTUnwrap(git(["rev-parse", "HEAD"], in: repo))
        git(["checkout", "--quiet", head], in: repo)
        XCTAssertEqual(checkout(repo).state(), .detached)
    }

    /// A repo made with `git init` rather than cloned has nothing to be behind.
    func testNoUpstream() throws {
        let repo = try makeRepo("local-only")
        XCTAssertEqual(checkout(repo).state(), .noUpstream)
    }

    func testAMissingPathIsNotARepository() {
        XCTAssertEqual(SourceCheckout.atPath("/nope/does/not/exist").state(), .notARepository)
    }

    // ── The sentence shown to a person ──────────────────────────────────────

    /// Every state says something, and only one of them says "Up to date" —
    /// a row that falls back to a generic string for the awkward states is how
    /// a user ends up staring at a disabled button with no explanation.
    func testEveryStateHasItsOwnSentence() {
        let states: [SourceCheckout.State] = [
            .missing, .notARepository, .detached, .dirty(changed: 2),
            .noUpstream, .upToDate, .behind(commits: 1),
        ]
        let sentences = states.map(SourceCheckout.summary)
        XCTAssertEqual(Set(sentences).count, states.count, "two states share a sentence")
        for s in sentences {
            XCTAssertFalse(s.isEmpty)
            XCTAssertTrue(s.hasSuffix(".") || s.hasSuffix("first."),
                          "\"\(s)\" is not a sentence")
        }
    }

    /// Singular and plural, because "1 commits behind" in a shipped app is the
    /// kind of thing people screenshot.
    func testCountsReadCorrectly() {
        XCTAssertEqual(SourceCheckout.summary(.behind(commits: 1)), "1 commit behind.")
        XCTAssertEqual(SourceCheckout.summary(.behind(commits: 4)), "4 commits behind.")
        XCTAssertTrue(SourceCheckout.summary(.dirty(changed: 1)).contains("1 uncommitted change"))
        XCTAssertTrue(SourceCheckout.summary(.dirty(changed: 3)).contains("3 uncommitted changes"))
    }

    /// Only `.behind` offers the button.
    func testOnlyBeingBehindOffersAnUpdate() {
        XCTAssertTrue(SourceCheckout.State.behind(commits: 1).isUpdatable)
        for s: SourceCheckout.State in [.missing, .notARepository, .detached,
                                        .dirty(changed: 1), .noUpstream, .upToDate] {
            XCTAssertFalse(s.isUpdatable, "\(s) offered an update it cannot perform")
        }
    }
}
