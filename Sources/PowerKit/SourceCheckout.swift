import Foundation

/// The source checkout this app was built from, and whether it is behind.
///
/// The app has no installer and no Sparkle feed — it is built from source by
/// whoever runs it, so "update" here means `git pull && ./build-app.sh` rather
/// than downloading a signed bundle. That makes the update question a question
/// about a working copy on disk, which is a thing with a lot of states: the
/// checkout can be gone, not a repo, on a detached HEAD, mid-rebase, dirty, or
/// have no remote at all. Each of those wants a different sentence, and a button
/// that says "Update" while any of them is true is a button that fails.
///
/// So the states are enumerated and the git calls are injectable, which lets the
/// whole thing be tested against a REAL repository built in a temp directory —
/// no network, no fixtures pretending to be git output, and no mocking of the
/// one part most likely to surprise us.
public struct SourceCheckout {

    /// What a caller may do about the checkout, and why.
    public enum State: Equatable {
        /// No path recorded, or nothing at that path any more.
        case missing
        /// The path exists but is not a git working copy.
        case notARepository
        /// On a detached HEAD or mid-operation. Pulling here is not a thing a
        /// user meant to ask for.
        case detached
        /// Tracked files are modified. `git pull --ff-only` would refuse, and
        /// silently stashing someone's work is not this button's job.
        case dirty(changed: Int)
        /// A repo with no upstream — a clone-less `git init`, or a fork with no
        /// remote set. There is nothing to be behind.
        case noUpstream
        case upToDate
        case behind(commits: Int)

        /// Can `update.sh` be run right now?
        public var isUpdatable: Bool {
            if case .behind = self { return true }
            return false
        }
    }

    /// Runs a git command in the checkout and returns its trimmed stdout, or nil
    /// if git could not be run or exited non-zero.
    public typealias GitRunner = (_ arguments: [String]) -> String?

    private let run: GitRunner

    public init(run: @escaping GitRunner) { self.run = run }

    /// The real thing: `git -C <path> …` via Process.
    ///
    /// `nil` for a non-zero exit rather than the error text, because every caller
    /// here treats "git said no" as one condition — the state machine below is
    /// what turns that into a sentence, and it needs to know WHICH question
    /// failed, not what git printed.
    public static func atPath(_ path: String) -> SourceCheckout {
        SourceCheckout { args in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["git", "-C", path] + args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            // A checkout on a slow or disconnected volume must not hang the
            // caller; `fetch` is the one that can, and it is given its own
            // timeout by the caller rather than being trusted.
            do { try p.run() } catch { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Where the checkout is, as recorded in the bundle at build time.
    ///
    /// `BSSourcePath` is written by `build-app.sh`. An app built before that key
    /// existed — or copied to another machine — simply has no answer, which is
    /// `.missing` rather than a guess: searching the disk for something that
    /// looks like the right repo is how an updater ends up rebuilding a stranger's
    /// clone.
    public static func recordedPath(in bundle: Bundle = .main) -> String? {
        guard let path = bundle.object(forInfoDictionaryKey: "BSSourcePath") as? String,
              !path.isEmpty else { return nil }
        return path
    }

    /// Ask the checkout where it stands. Does NOT fetch — see `fetch()`.
    public func state() -> State {
        // `--is-inside-work-tree` rather than testing for a `.git` directory: a
        // worktree's `.git` is a FILE, and a subdirectory of a repo has no `.git`
        // at all while still being perfectly updatable.
        guard run(["rev-parse", "--is-inside-work-tree"]) == "true" else {
            return .notARepository
        }
        // A detached HEAD prints "HEAD"; a branch prints its name.
        guard let branch = run(["rev-parse", "--abbrev-ref", "HEAD"]), branch != "HEAD" else {
            return .detached
        }
        // Tracked modifications only. Untracked files are not in the way of a
        // fast-forward and stopping for them would make the button useless in
        // any checkout that has ever been built in (`.build/`, `*.app`).
        if let changed = run(["diff", "--name-only", "HEAD"]),
           !changed.isEmpty {
            return .dirty(changed: changed.split(separator: "\n").count)
        }
        guard let upstream = run(["rev-parse", "--abbrev-ref", "@{upstream}"]),
              !upstream.isEmpty else { return .noUpstream }
        guard let count = run(["rev-list", "--count", "HEAD..@{upstream}"]),
              let behind = Int(count) else { return .noUpstream }
        return behind == 0 ? .upToDate : .behind(commits: behind)
    }

    /// Refresh the upstream ref. Separate from `state()` because it touches the
    /// network: a settings window opening should not block on someone's Wi-Fi,
    /// and the answer without a fetch is still true, just older.
    @discardableResult
    public func fetch() -> Bool { run(["fetch", "--quiet"]) != nil }

    /// One line, for the row in Preferences.
    public static func summary(_ state: State) -> String {
        switch state {
        case .missing:
            return "Built somewhere this app can no longer find. "
                 + "Update by running ./build-app.sh in your checkout."
        case .notARepository:
            return "The source folder is not a git checkout, so there is nothing to pull."
        case .detached:
            return "The checkout is not on a branch. Sort that out in git first."
        case .dirty(let n):
            return "\(n) uncommitted \(n == 1 ? "change" : "changes") in the checkout — "
                 + "commit or stash them first. Nothing here will touch your work."
        case .noUpstream:
            return "The checkout has no upstream, so there is nothing to compare against."
        case .upToDate:
            return "Up to date."
        case .behind(let n):
            return "\(n) \(n == 1 ? "commit" : "commits") behind."
        }
    }
}
