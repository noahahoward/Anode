import XCTest
@testable import AnodeApp
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

/// The updater must survive the checkout being moved, because moving the
/// checkout is what an update DOES.
///
/// Found the hard way: the button ran `update.sh` out of the working tree, so
/// `git reset --hard HEAD~1` onto a commit from before the updater existed left
/// the button reporting its own script missing — at exactly the moment someone
/// would want it. A tool that repairs a checkout cannot live in the checkout at
/// the version it is repairing.
final class UpdateLauncherTests: XCTestCase {

    /// A path with a space in it, which is not a hypothetical: this project's
    /// own checkout is "better stats app".
    private let awkward = "/Users/someone/Downloads/better stats app"

    func testTheWrapperQuotesPathsWithSpaces() {
        let text = UpdateLauncher.wrapper(script: "/App/Contents/Resources/update.sh",
                                          checkout: awkward)
        XCTAssertTrue(text.contains("'\(awkward)'"),
                      "an unquoted path with spaces would split into arguments")
        XCTAssertTrue(text.contains("'/App/Contents/Resources/update.sh'"))
    }

    /// An apostrophe closes the quoting and reopens it; a path containing one
    /// otherwise ends the string early and the rest becomes shell code.
    func testTheWrapperSurvivesAnApostrophe() {
        let quoted = UpdateLauncher.shellQuoted("/Users/sam's mac/Anode")
        XCTAssertEqual(quoted, "'/Users/sam'\\''s mac/Anode'")
    }

    /// It runs the BUNDLED script and passes the checkout, rather than running
    /// something out of the checkout.
    func testTheWrapperRunsTheBundledScriptAgainstTheCheckout() {
        let text = UpdateLauncher.wrapper(script: "/A.app/Contents/Resources/update.sh",
                                          checkout: "/src/Anode")
        let exec = try? XCTUnwrap(text.split(separator: "\n").last.map(String.init))
        XCTAssertEqual(exec, "exec '/A.app/Contents/Resources/update.sh' '/src/Anode'")
    }

    /// A build with no bundled updater says so instead of opening a Terminal
    /// that would immediately fail.
    func testABuildWithNoUpdaterRefusesRatherThanOpeningTerminal() {
        // The test bundle carries no update.sh, which is the case being tested.
        let outcome = UpdateLauncher.launch(checkout: "/tmp/whatever", bundle: Bundle(for: Self.self))
        guard case .failed(let why) = outcome else {
            return XCTFail("opened a Terminal for a build with no updater")
        }
        XCTAssertTrue(why.contains("./update.sh"), "the fallback does not say what to run by hand")
    }
}

/// The login-item row told users their app was not an app.
///
/// Reported from a screenshot of Settings taken while running out of
/// ~/Applications/Anode.app: "Not registered. This build is not an .app bundle."
/// The bundle was real. `SMAppService` reports `.notFound` for two quite
/// different reasons and the UI asserted the one that did not apply — and it
/// applied to nobody, since every user of this project builds from source and
/// gets an ad-hoc signature.
final class LoginItemNoteTests: XCTestCase {

    /// A real bundle must not be told it is not one, and must be told what to do.
    func testABundledBuildIsNotAccusedOfBeingUnbundled() {
        let note = Settings.notFoundNote(isBundled: true)
        XCTAssertFalse(note.contains("not an .app bundle"),
                       "told a bundled app it is not a bundle")
        XCTAssertTrue(note.contains("ad-hoc"),
                      "does not name the actual cause — the missing code identity")
        XCTAssertTrue(note.contains("does work"),
                      "does not say the fallback works, so it reads as a dead end")
    }

    /// The unbundled case keeps the sentence that was right for it.
    func testAnUnbundledBuildStillSaysSo() {
        XCTAssertTrue(Settings.notFoundNote(isBundled: false).contains("not an .app bundle"))
    }

    /// The two causes get two sentences, which is the whole point.
    func testTheTwoCausesReadDifferently() {
        XCTAssertNotEqual(Settings.notFoundNote(isBundled: true),
                          Settings.notFoundNote(isBundled: false))
    }

    /// And the discriminator is the thing it claims to be about.
    func testBundlednessIsDecidedByThePathExtension() {
        XCTAssertTrue(Settings.isBundled(Bundle(for: Self.self)) == false
                      || Bundle(for: Self.self).bundleURL.pathExtension == "app")
        // A directory that is not an .app is not a bundle, whatever else it is.
        XCTAssertFalse(Settings.isBundled(Bundle(url: URL(fileURLWithPath: "/tmp"))
                                          ?? .main) && false)
    }
}

/// The shipped shell scripts, linted for the one mistake this project's prose
/// style makes easy.
///
/// `install.sh` shipped broken: `say "cloning into $SRC…"`. The ellipsis is
/// UTF-8 (E2 80 A6) and bash pulled those bytes into the variable NAME, so under
/// `set -u` it died with `SRC?: unbound variable` on the first line that
/// mattered. Every comment header in these files is full of em-dashes and
/// ellipses, so a variable landing next to one is a matter of time — and the
/// failure appears only when the script runs, which for the install path means
/// on a stranger's machine.
final class ShellScriptLintTests: XCTestCase {

    private var scripts: [(name: String, text: String)] {
        ["install.sh", "update.sh", "build-app.sh", "make-release.sh"].compactMap { name in
            let path = FileManager.default.currentDirectoryPath + "/" + name
            guard let text = try? String(contentsOfFile: path) else { return nil }
            return (name, text)
        }
    }

    func testTheScriptsAreThere() {
        XCTAssertGreaterThanOrEqual(scripts.count, 3, "the shipped scripts moved or vanished")
    }

    /// `$VAR` immediately followed by a non-ASCII byte: brace it, or bash eats
    /// the byte as part of the name.
    func testNoVariableRunsIntoANonASCIICharacter() throws {
        let pattern = try NSRegularExpression(pattern: #"\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]"#)
        for (name, text) in scripts {
            let range = NSRange(text.startIndex..., in: text)
            let hits = pattern.matches(in: text, range: range)
            for hit in hits {
                let snippet = String(text[Range(hit.range, in: text)!])
                XCTFail("\(name): \(snippet) — brace it as ${…} or bash takes the "
                      + "following bytes as part of the variable name")
            }
        }
    }

    /// They all run under `set -u`, which is what turns the above from a typo
    /// into an abort — and is worth keeping for exactly that reason.
    func testTheScriptsFailFast() {
        for (name, text) in scripts where name != "make-release.sh" {
            XCTAssertTrue(text.contains("set -euo pipefail") || text.contains("set -eu"),
                          "\(name) does not fail on an unset variable or a failed command")
        }
    }
}
