import AppKit
import PowerKit

// Memory Watch: what the diagnostic window's two buttons are allowed to do, decided and carried out here.
//
// The window never signals anything itself. It asks a `MemoryWatchQuitting` for a PLAN (what is still running, whose it is,
// whether it is macOS's own), shows the plan, and on a click hands the plan back to be performed. Every step that touches the
// Mac (reading a process, listing pids, the signal, the confirmation box) is a closure given to the quitter, so the tests
// play the whole of it with fakes: no real process is read, no signal is sent, no modal appears.
//
// SAFETY, in the order it is checked on every plan:
//   1. The flagged pid is read again and its START TIME must still equal the finding's. A recycled pid has another start
//      time, so a process that exited and whose pid was reused is never signalled: the plan says "already exited".
//   2. An `.app` finding is the app's processes: every pid whose executable path begins with `<bundle>/`. A string match, no
//      rusage call.
//   3. Anything that is NOT an app is exactly ONE process, the verified pid. It is never widened by name or by
//      `AppResolver` identity, because every non-app resolves to the same identity and that would collect every `node` on
//      the Mac.
//   4. Anode's own pid, and anything under Anode's own bundle, is never offered.
//   5. Another user's processes are refused up front (`ProcessActions.plan`), never failed at the click.

/// What one click may do, worked out before the button is drawn and again when it is clicked.
struct MemoryWatchQuitPlan {
    /// True for an `.app` finding (Quit App acts on every process of the app), false for one lone process.
    var wholeApp: Bool
    /// The app's name for an app, else the process's name.
    var appName: String
    /// The process that was flagged, and the start time it must still have.
    var flaggedPID: pid_t
    var flaggedStart: UInt64
    /// The pids Anode may signal: same user, never Anode's own.
    var signalable: [pid_t]
    /// Pids that would fail with EPERM, and who owns them.
    var refused: [(pid: pid_t, owner: String)]
    /// Anode's own pid (or a pid under Anode's bundle) was among them and is left out.
    var includesSelf: Bool
    /// Set when the process is macOS's own (Finder, the Dock, the login window, an Apple daemon).
    var systemProcessWarning: String?
    /// The flagged process has exited, or its pid now belongs to another process. Nothing is signalled.
    var alreadyGone: Bool

    init(wholeApp: Bool, appName: String, flaggedPID: pid_t, flaggedStart: UInt64,
         signalable: [pid_t] = [], refused: [(pid: pid_t, owner: String)] = [], includesSelf: Bool = false,
         systemProcessWarning: String? = nil, alreadyGone: Bool = false) {
        self.wholeApp = wholeApp
        self.appName = appName
        self.flaggedPID = flaggedPID
        self.flaggedStart = flaggedStart
        self.signalable = signalable
        self.refused = refused
        self.includesSelf = includesSelf
        self.systemProcessWarning = systemProcessWarning
        self.alreadyGone = alreadyGone
    }

    /// How many processes a click would signal. This is the number the confirmation states.
    var processCount: Int { signalable.count }
    /// Every process of the app that is still running, signalable or not.
    var totalProcessCount: Int { signalable.count + refused.count }
    var canAct: Bool { !alreadyGone && !signalable.isEmpty }

    /// The plan as `ProcessActions` knows it, so the signalling and its wording are the existing code, not a copy.
    var actions: ProcessActions.Plan {
        ProcessActions.Plan(signalable: signalable, refused: refused, includesSelf: includesSelf)
    }

    /// Why a button is disabled, or what is partly refused; empty when there is nothing to say.
    var explanation: String {
        if alreadyGone { return MemoryWatchQuitter.alreadyExitedLine }
        return actions.explanation
    }
}

protocol MemoryWatchQuitting: AnyObject {
    /// Works the plan out off the main thread and calls `completion` on the main thread.
    func plan(for finding: Finding, completion: @escaping (MemoryWatchQuitPlan) -> Void)
    /// Carries the plan out and returns the line for the status label. A Force Quit asks first; a polite Quit does not.
    /// Call it on the main thread (the confirmation is a modal box).
    func perform(_ plan: MemoryWatchQuitPlan, force: Bool) -> String
    /// Whether any process of the plan is still running. Off the main thread; `completion` on the main thread.
    func isStillRunning(_ plan: MemoryWatchQuitPlan, completion: @escaping (Bool) -> Void)
}

extension MemoryWatchQuitting {
    /// A quitter that cannot tell says it has closed, so the window never claims "still running" without knowing.
    func isStillRunning(_ plan: MemoryWatchQuitPlan, completion: @escaping (Bool) -> Void) { completion(false) }
}

final class MemoryWatchQuitter: MemoryWatchQuitting {

    // MARK: Words (the window and the tests read the same ones)

    static let alreadyExitedLine = "That process already exited"
    static let quitRequestedLine = "Quit requested, waiting for it to close"
    static let stillRunningLine = "Still running; it may be asking to save. Use Force Quit if it is stuck."
    static let closedLine = "It has closed."
    static let cancelledLine = "Force Quit cancelled. Nothing was closed."

    // MARK: Injected

    typealias Reading = (start: UInt64, footprint: UInt64)

    private let probe: (pid_t) -> Reading?
    private let allPIDs: () -> [pid_t]
    private let pathOf: (pid_t) -> String
    private let candidates: ([pid_t]) -> [ProcessActions.Candidate]
    /// The app's bundle id and how macOS lists it, from the app's pids (`nil` id when it is not running as an app).
    private let bundleInfo: (_ identityKey: String, _ pids: [pid_t]) -> (id: String?, kind: AppKind)
    private let selfPID: pid_t
    private let currentUID: uid_t
    /// Anode's own pids beyond `selfPID` (a worker copy).
    private let ownPIDs: () -> Set<pid_t>
    /// Anode's own bundle path and executable path: a finding on one of them is Anode itself.
    private let ownPaths: Set<String>
    private let signaller: (ProcessActions.Plan, Bool) -> String
    private let confirm: (MemoryWatchQuitPlan) -> Bool
    /// Runs work off the main thread, and hands a result back on it.
    private let runOffMain: (@escaping () -> Void) -> Void
    private let runOnMain: (@escaping () -> Void) -> Void

    init(probe: @escaping (pid_t) -> Reading? = { pid in
             ProcessSampler.footprint(of: pid).map { (start: $0.start, footprint: $0.footprint) } },
         allPIDs: @escaping () -> [pid_t] = { ProcessSampler.allPIDs() },
         pathOf: @escaping (pid_t) -> String = { ProcessSampler.path(of: $0) },
         candidates: @escaping ([pid_t]) -> [ProcessActions.Candidate] = { ProcessActions.candidates(pids: $0) },
         bundleInfo: @escaping (String, [pid_t]) -> (id: String?, kind: AppKind) = MemoryWatchQuitter.liveBundleInfo,
         selfPID: pid_t = getpid(),
         currentUID: uid_t = getuid(),
         ownPIDs: @escaping () -> Set<pid_t> = { [] },
         ownPaths: Set<String> = MemoryWatchQuitter.liveOwnPaths(),
         signal: @escaping (ProcessActions.Plan, Bool) -> String = { ProcessActions.perform($0, force: $1) },
         confirm: @escaping (MemoryWatchQuitPlan) -> Bool = MemoryWatchQuitter.liveConfirm,
         runOffMain: @escaping (@escaping () -> Void) -> Void = { work in DispatchQueue.global(qos: .userInitiated).async { work() } },
         runOnMain: @escaping (@escaping () -> Void) -> Void = { work in DispatchQueue.main.async { work() } }) {
        self.probe = probe
        self.allPIDs = allPIDs
        self.pathOf = pathOf
        self.candidates = candidates
        self.bundleInfo = bundleInfo
        self.selfPID = selfPID
        self.currentUID = currentUID
        self.ownPIDs = ownPIDs
        self.ownPaths = ownPaths
        self.signaller = signal
        self.confirm = confirm
        self.runOffMain = runOffMain
        self.runOnMain = runOnMain
    }

    /// The quitter that reads and signals the real Mac.
    static func live() -> MemoryWatchQuitter { MemoryWatchQuitter() }

    // MARK: Plan

    func plan(for finding: Finding, completion: @escaping (MemoryWatchQuitPlan) -> Void) {
        runOffMain { [self] in
            let result = resolve(finding)
            runOnMain { completion(result) }
        }
    }

    /// The whole decision, synchronously. The tests call this directly; `plan(for:completion:)` only moves it off the
    /// main thread.
    func resolve(_ finding: Finding) -> MemoryWatchQuitPlan {
        let whole = finding.isApp
        func gone() -> MemoryWatchQuitPlan {
            MemoryWatchQuitPlan(wholeApp: whole, appName: finding.name, flaggedPID: finding.pid,
                                flaggedStart: finding.processKey.startAbsTime, alreadyGone: true)
        }

        // 1. The process must still be the one that was flagged.
        guard finding.pid > 0, finding.processKey.pid == finding.pid,
              let reading = probe(finding.pid), reading.start == finding.processKey.startAbsTime else { return gone() }

        // 2 and 3. An app is every process under its bundle; anything else is the one verified pid and nothing more.
        var pids: [pid_t] = [finding.pid]
        if whole, finding.identityKey.hasSuffix(".app") {
            // Only the app's own processes (its main executable and its nested helper bundles), never a tool that merely
            // lives under the same folder: Xcode's python3 or language server is not "Xcode".
            for pid in allPIDs() where pid != finding.pid
                && IdentityKey.belongsToApp(path: pathOf(pid), bundle: finding.identityKey) { pids.append(pid) }
        }
        pids.sort()

        // 4. Anode itself is never offered: not its pid, not a worker copy, not anything under its own bundle.
        let isOwnApp = ownPaths.contains(finding.identityKey) || ownPaths.contains(finding.path)
        let ownSet = ownPIDs().union([selfPID])
        let ownFound = pids.filter { isOwnApp || ownSet.contains($0) }
        let others = pids.filter { !(isOwnApp || ownSet.contains($0)) }

        // 5. The same uid rule as the Processes inspector, by the same code.
        let base = ProcessActions.plan(for: candidates(others), currentUID: currentUID, selfPID: selfPID)
        if base.signalable.isEmpty, base.refused.isEmpty, ownFound.isEmpty, !base.includesSelf { return gone() }

        // macOS's own processes get an extra line before a Force Quit.
        var warning: String?
        if !isOwnApp {
            let info: (id: String?, kind: AppKind) = whole ? bundleInfo(finding.identityKey, pids) : (id: nil, kind: AppKind.none)
            let process = UltraProcess(pid: finding.pid, parent: 0, uid: currentUID,
                                       startTime: finding.processKey.startAbsTime, path: finding.path,
                                       app: info.kind, bundleID: info.id, name: finding.name)
            // `FreezePlanner` counts everything under /usr as the system's; /usr/local is where people's own tools live.
            if FreezePlanner.isSystem(process), !finding.path.hasPrefix("/usr/local/") {
                warning = "\(finding.name) is part of macOS. Quitting it can disturb the desktop or other apps."
            }
        }

        return MemoryWatchQuitPlan(wholeApp: whole, appName: finding.name, flaggedPID: finding.pid,
                                   flaggedStart: finding.processKey.startAbsTime,
                                   signalable: base.signalable, refused: base.refused,
                                   includesSelf: base.includesSelf || !ownFound.isEmpty,
                                   systemProcessWarning: warning, alreadyGone: false)
    }

    // MARK: Perform

    func perform(_ plan: MemoryWatchQuitPlan, force: Bool) -> String {
        guard plan.canAct else {
            let why = plan.explanation
            return why.isEmpty ? "Nothing to quit" : why
        }
        // Only a Force Quit is confirmed. A polite Quit leaves the app to ask about its own unsaved work, and a box in
        // front of the app's box teaches people to dismiss both (the same rule as the Processes inspector).
        if force, !confirm(plan) { return Self.cancelledLine }
        let result = signaller(plan.actions, force)
        if !force, result.hasPrefix("Quit requested for") {
            return Self.quitRequestedLine
                + (plan.refused.isEmpty ? "" : " (\(plan.refused.count) not permitted)")
        }
        return result
    }

    // MARK: Still running

    func isStillRunning(_ plan: MemoryWatchQuitPlan, completion: @escaping (Bool) -> Void) {
        runOffMain { [self] in
            let alive = stillRunning(plan)
            runOnMain { completion(alive) }
        }
    }

    func stillRunning(_ plan: MemoryWatchQuitPlan) -> Bool {
        for pid in plan.signalable {
            guard let reading = probe(pid) else { continue }
            // The flagged process is told apart from a recycled pid by its start time; the rest, in ten seconds, are not
            // worth the second lookup.
            if pid == plan.flaggedPID, reading.start != plan.flaggedStart { continue }
            return true
        }
        return false
    }

    // MARK: The confirmation

    /// The words of the Force Quit box. They always say how many processes will be killed, that unsaved work may be lost,
    /// and whether it is the whole app or one process.
    static func confirmationText(appName: String, processCount: Int, wholeApp: Bool,
                                 systemWarning: String? = nil) -> (title: String, detail: String) {
        let count = processCount == 1 ? "1 process" : "\(processCount) processes"
        let title = wholeApp ? "Force quit \(appName)?" : "Force quit this \(appName) process?"
        var paragraphs: [String] = []
        paragraphs.append(wholeApp
            ? "This force quits the whole app, not only the process that is growing."
            : "This force quits only this one process. Nothing else is touched.")
        paragraphs.append("This will kill \(count).")
        paragraphs.append("Force quitting cannot be caught or deferred, so unsaved work may be lost.")
        if let systemWarning { paragraphs.append(systemWarning) }
        return (title, paragraphs.joined(separator: "\n\n"))
    }

    /// The box itself. A modal: only ever called from `perform`, which the tests give a fake confirmation.
    static func confirmForceQuit(appName: String, processCount: Int, wholeApp: Bool,
                                 systemWarning: String? = nil) -> Bool {
        let text = confirmationText(appName: appName, processCount: processCount, wholeApp: wholeApp,
                                    systemWarning: systemWarning)
        let alert = NSAlert()
        alert.messageText = text.title
        alert.informativeText = text.detail
        alert.alertStyle = .warning
        // The caution icon stays: this is the one box in the app that kills things, and the standard sign is worth its
        // column of space.
        let force = alert.addButton(withTitle: "Force Quit")
        force.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func liveConfirm(_ plan: MemoryWatchQuitPlan) -> Bool {
        confirmForceQuit(appName: plan.appName, processCount: plan.processCount, wholeApp: plan.wholeApp,
                         systemWarning: plan.systemProcessWarning)
    }

    // MARK: Live lookups

    /// What macOS says the app is, from the running app itself and not from its Info.plist: reading a bundle's files could
    /// raise a consent prompt for a folder (Downloads, Desktop) the app happens to sit in, and a running app is already
    /// known to LaunchServices.
    static func liveBundleInfo(identityKey: String, pids: [pid_t]) -> (id: String?, kind: AppKind) {
        for pid in pids {
            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.bundleURL?.path == identityKey else { continue }
            switch app.activationPolicy {
            case .regular: return (app.bundleIdentifier, .regular)
            case .accessory: return (app.bundleIdentifier, .accessory)
            default: return (app.bundleIdentifier, AppKind.none)
            }
        }
        return (nil, .regular)
    }

    static func liveOwnPaths() -> Set<String> {
        var paths: Set<String> = [Bundle.main.bundlePath]
        if let exe = Bundle.main.executablePath { paths.insert(exe) }
        return paths
    }
}
