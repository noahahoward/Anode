import AppKit
import PowerKit

/// Quitting things, and deciding beforehand what can actually be quit.
///
/// Three verbs, matching what people already know from Activity Monitor:
///
///   Quit app             — ask every process of the app politely. A GUI process
///                          gets the Quit Apple Event, so it can prompt about
///                          unsaved work; anything else gets SIGTERM.
///   Force quit app       — SIGKILL every process of the app. Uncatchable.
///   Force quit process   — SIGKILL the one selected sub-process, leaving the rest
///                          of the app running. This is the surgical one: a pinned
///                          renderer or a wedged extension host.
///
/// THE PLAN IS SEPARATE FROM THE SIGNAL, deliberately. Deciding what a button
/// should do — which pids are ours to signal, which are root's, whether anything is
/// left to offer at all — is the part that has to be right, and it is the part that
/// cannot be tested if it is entangled with `kill(2)`. `Plan` is pure, and the tests
/// drive it with synthetic processes. `perform` is the only function that signals,
/// and it does no deciding.
enum ProcessActions {

    /// What a button will do, worked out before it is drawn.
    struct Plan {
        /// Pids this app can actually signal: same uid, and not Anode itself.
        let signalable: [pid_t]
        /// Pids that would fail with EPERM, and who owns them. Never offered.
        let refused: [(pid: pid_t, owner: String)]
        /// True when the user clicked on Anode' own row.
        let includesSelf: Bool

        var canAct: Bool { !signalable.isEmpty }

        /// The one-line explanation shown beside the buttons.
        ///
        /// It always states the EPERM case explicitly rather than letting the
        /// button fail quietly: "Not permitted" after a click reads as a bug in the
        /// app, and the truth — this belongs to root, no unprivileged process can
        /// signal it — is both simple and worth knowing.
        var explanation: String {
            if includesSelf, signalable.isEmpty, refused.isEmpty {
                return "This is Anode"
            }
            guard !refused.isEmpty else { return "" }
            let owners = Set(refused.map(\.owner)).sorted().joined(separator: ", ")
            if signalable.isEmpty {
                return refused.count == 1
                    ? "Owned by \(owners) — Anode cannot signal it"
                    : "Owned by \(owners) — Anode cannot signal these"
            }
            return "\(refused.count) of \(refused.count + signalable.count) owned by "
                 + "\(owners) and cannot be signalled"
        }
    }

    /// The facts a plan is made from. A struct rather than a `pid_t` so the
    /// decision can be driven in a test without a live process to read.
    struct Candidate {
        let pid: pid_t
        let uid: uid_t
        let owner: String
        init(pid: pid_t, uid: uid_t, owner: String) {
            self.pid = pid
            self.uid = uid
            self.owner = owner
        }
    }

    /// - Parameters:
    ///   - currentUID: the uid this app runs as.
    ///   - selfPID: Anode' own pid, which is never offered — quitting the
    ///     monitor from inside its own process list is almost certainly a misclick,
    ///     and the app cannot report the outcome of its own death.
    static func plan(for candidates: [Candidate],
                     currentUID: uid_t = getuid(),
                     selfPID: pid_t = getpid()) -> Plan {
        var signalable: [pid_t] = []
        var refused: [(pid: pid_t, owner: String)] = []
        var includesSelf = false
        for c in candidates {
            // Our own pid is skipped rather than refused: it is not an EPERM case
            // and saying "not permitted" about ourselves would be a lie.
            if c.pid == selfPID { includesSelf = true; continue }
            // The uid test lives in PowerKit so that the "safe to quit?" sentence
            // in the inspector and the enabled state of these buttons are decided
            // by ONE predicate. Two copies could drift, and a sentence that
            // disagrees with the button beside it is worse than either alone.
            if ProcessSignalability.canSignal(pid: c.pid, uid: c.uid,
                                              currentUID: currentUID, selfPID: selfPID) {
                signalable.append(c.pid)
            } else {
                refused.append((c.pid, c.owner))
            }
        }
        return Plan(signalable: signalable, refused: refused, includesSelf: includesSelf)
    }

    /// Read the uid of every pid the app owns. Pids that have already exited are
    /// dropped: a process that is gone is not a process we failed to signal.
    static func candidates(pids: [pid_t]) -> [Candidate] {
        pids.compactMap { pid in
            guard let d = ProcessInspector.details(for: pid) else { return nil }
            return Candidate(pid: pid, uid: d.uid, owner: d.userName ?? "uid \(d.uid)")
        }
    }

    // ── Signalling ──────────────────────────────────────────────────────────

    /// What happened, in one line, for the status label.
    static func perform(_ plan: Plan, force: Bool) -> String {
        guard plan.canAct else { return plan.explanation }
        var succeeded = 0
        var failures: [ProcessControl.Result] = []
        for pid in plan.signalable {
            let result = force ? ProcessControl.forceQuit(pid: pid) : ProcessControl.quit(pid: pid)
            switch result {
            // `.noSuchProcess` is not a failure: an app quitting takes its helpers
            // with it, so by the time the third pid is signalled it has often
            // already gone. Reporting that as an error would make a successful
            // quit look like a broken one.
            case .requested, .killed, .noSuchProcess: succeeded += 1
            default: failures.append(result)
            }
        }
        let verb = force ? "Force quit" : "Quit requested for"
        if failures.isEmpty {
            let subject = succeeded == 1 ? "1 process" : "\(succeeded) processes"
            return plan.refused.isEmpty
                ? "\(verb) \(subject)"
                : "\(verb) \(subject) · \(plan.refused.count) not permitted"
        }
        // Name the first distinct failure rather than a count alone: "errno 3" is
        // the only thing that distinguishes a bug here from a race.
        let reason = failures.first?.message ?? "failed"
        return "\(succeeded) of \(plan.signalable.count) — \(reason)"
    }

    /// Confirmation before anything uncatchable.
    ///
    /// SIGKILL cannot be caught, blocked or deferred, so unsaved work is simply
    /// gone — that warrants asking in a way an ordinary quit does not. The polite
    /// quit is NOT confirmed: the app itself will prompt about unsaved work, and a
    /// dialog in front of a dialog is how people learn to dismiss both.
    static func confirmForceQuit(subject: String, processCount: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Force quit \(subject)?"
        var detail = "Force quitting sends SIGKILL, which the process cannot catch. "
                   + "Any unsaved work will be lost."
        if processCount > 1 {
            detail += "\n\nThis will kill \(processCount) processes."
        }
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Force Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
