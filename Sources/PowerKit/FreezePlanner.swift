import Foundation

/// Which processes Ultra Low Power Mode keeps, stops and leaves alone. No system calls: it is given every process on
/// the Mac and returns three piles of groups.
///
/// A GROUP is an app and everything that belongs to it, or one background tool and what it started. A group is stopped
/// whole or not at all: stopping an app's window process and leaving its network process running is how a Mac ends up
/// burning power for an app that is not on screen.
///
/// Who a process belongs to (its OWNER), in this order, again and again until it stops changing:
///   1. the process macOS holds responsible for it, when that one is in the list;
///   2. else the nearest ancestor that is an app, or that was started by launchd (parent 1). A tool run from the
///      editor's terminal is that way the editor's, whatever file it was started from;
///   3. else, when that ancestor's file sits inside a bundle of a running app, that app. This ties the launchd-started
///      helpers and services of an app to it.
/// "Belongs to" wins over where the file lives: a browser's page process lives in the system folders and is still the
/// browser's. Only when nothing ties a system-located process to an app is it the system's, and left alone.
///
/// A process that cannot be signalled (another user's) or that is Anode's own is never a member of a group, and neither
/// is anything that belongs to the system, to another user or to Anode: they form no group, so no list names them.
public enum FreezePlanner {

    public static func plan(processes: [UltraProcess], user: uid_t, front: pid_t?, alwaysKeep: Set<String>,
                            ownPIDs: Set<pid_t>) -> FreezePlan {
        let index = ProcessIndex(processes)
        let others = OtherUsers(processes, user: user)
        let frontID = front.flatMap { index.byPID[$0] }
            .flatMap { touchableOwner(of: $0, index: index, user: user, ownPIDs: ownPIDs) }
            .map(groupID)

        var kept: [FreezeGroup] = [], frozen: [FreezeGroup] = [], leftRunning: [FreezeGroup] = []
        for draft in groups(processes, index: index, user: user, ownPIDs: ownPIDs) {
            if draft.id == frontID || alwaysKeep.contains(draft.id) || draft.processes.contains(where: \.usesMicOrCamera) {
                // Everything of a kept group is named: they are the processes the mode will leave running.
                kept.append(draft.group(of: draft.processes))
                continue
            }
            // One process that owns a tap keeps the whole app running: a stopped tap owner can stall the keyboard and
            // pointer for the whole Mac until the tap times out.
            if draft.processes.contains(where: \.ownsEventTap) { continue }
            // Extensions that macOS hosts for an app are left running even when the app is stopped. A process that was stopped
            // already is not Anode's: it is never signalled, so it is never continued at the end. The group is still frozen
            // for the rest of its members.
            let members = draft.processes.filter { !isExtension($0) && !$0.stopped }
            if members.isEmpty { continue }
            if others.shareAProduct(with: draft.processes) {
                leftRunning.append(draft.group(of: members))
            } else {
                frozen.append(draft.group(of: members))
            }
        }
        return FreezePlan(kept: ordered(kept), frozen: ordered(frozen), leftRunning: ordered(leftRunning))
    }

    /// New members of groups already frozen, for the sweep. Released groups and kept groups never gain members.
    public static func additions(processes: [UltraProcess], user: uid_t, frozenGroups: Set<String>,
                                 known: Set<pid_t>, ownPIDs: Set<pid_t>) -> [FreezeGroup] {
        let index = ProcessIndex(processes)
        var result: [FreezeGroup] = []
        for draft in groups(processes, index: index, user: user, ownPIDs: ownPIDs) where frozenGroups.contains(draft.id) {
            // The group was stopped before this process existed, so the plan's group-wide rules were not asked about
            // it: ask them of the process itself. Stopping a new tap owner, or a helper that has just started on a
            // call, would do what those rules exist to prevent.
            let fresh = draft.processes.filter {
                !known.contains($0.pid) && !isExtension($0) && !$0.ownsEventTap && !$0.usesMicOrCamera && !$0.stopped
            }
            if !fresh.isEmpty { result.append(draft.group(of: fresh)) }
        }
        return ordered(result)
    }

    /// The group id of every process that is in a group, with the same owner rules as the plan: so a caller never has to
    /// work out who belongs to whom itself. Extensions are in it (they are in their app's group, though the plan never
    /// stops them); the system's processes, another user's and Anode's own are not, because they are in no group.
    public static func groupIDs(processes: [UltraProcess], user: uid_t, ownPIDs: Set<pid_t>) -> [pid_t: String] {
        var ids: [pid_t: String] = [:]
        for draft in groups(processes, index: ProcessIndex(processes), user: user, ownPIDs: ownPIDs) {
            for process in draft.processes { ids[process.pid] = draft.id }
        }
        return ids
    }

    /// What macOS itself is, as against an app the owner opened: system files that are not an app, the system's agents
    /// that are apps without a Dock icon, and the three that hold the screen together (Finder, the Dock, the login window).
    /// A regular app of Apple's (the mail app, the browser) is not system: the owner opened it.
    ///
    /// A background service that is no app and carries Apple's id or job label is system wherever its file is: the
    /// developer tools keep theirs under /Library/Developer, outside the system folders, and an IDE that is kept needs them.
    ///
    /// An input method is system wherever its file is (its folder is "Input Methods", in the system's library or the owner's): the
    /// one in use takes every key that is typed in every app, and stopping it stalls them all.
    public static func isSystem(_ p: UltraProcess) -> Bool {
        if isInputMethod(p) { return true }
        if let id = p.bundleID, systemBundles.contains(id) { return true }
        switch p.app {
        case .none:
            if p.bundleID?.hasPrefix("com.apple.") == true || p.launchdLabel?.hasPrefix("com.apple.") == true { return true }
            return systemRoots.contains { p.path.hasPrefix($0) }
        case .accessory: return p.bundleID?.hasPrefix("com.apple.") == true
        case .regular: return false
        }
    }

    // ── Groups ──────────────────────────────────────────────────────────────

    private static func isInputMethod(_ p: UltraProcess) -> Bool { p.path.contains("/Input Methods/") }

    private static let systemRoots = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"]
    private static let systemBundles: Set<String> = ["com.apple.finder", "com.apple.dock", "com.apple.loginwindow"]

    /// The user's processes, gathered by group id. A process whose owner is the system's, another user's or Anode's is
    /// dropped BEFORE ids are compared, so a system `runner` and the owner's own `runner` (both "exe:runner") are
    /// never one group: neither's flags can decide for the other.
    private static func groups(_ processes: [UltraProcess], index: ProcessIndex, user: uid_t, ownPIDs: Set<pid_t>) -> [Draft] {
        var drafts: [String: Draft] = [:]
        // An input method is no member of any group either, whoever macOS holds responsible for it.
        for p in processes where p.uid == user && !ownPIDs.contains(p.pid) && !isInputMethod(p) {
            guard let owner = touchableOwner(of: p, index: index, user: user, ownPIDs: ownPIDs) else { continue }
            let id = groupID(owner)
            var draft = drafts[id] ?? Draft(id: id, name: owner.name, namedBy: owner.pid)
            // Two owners can share an id (two copies of an app): the lowest pid names the group, so the name does not
            // depend on the order of the list.
            if owner.pid < draft.namedBy { draft.name = owner.name; draft.namedBy = owner.pid }
            draft.processes.append(p)
            drafts[id] = draft
        }
        return Array(drafts.values)
    }

    /// The owner of `p`, or nil when that owner is not the planner's to decide about: not the user's (it could not be
    /// signalled), Anode's own, the system's, or one nothing is known about.
    ///
    /// Nothing is known about a process that is no app and whose path could not be read: it may well be a system daemon,
    /// and unrelated ones of the same name would become one "exe:" group. Left alone, never frozen. This is only about
    /// an OWNER. A member with no readable path that is tied to an app by `responsible` or by its parents is still
    /// frozen with that app (a blind spot we accept: it could in theory be a system helper that app is held responsible for).
    private static func touchableOwner(of p: UltraProcess, index: ProcessIndex, user: uid_t,
                                       ownPIDs: Set<pid_t>) -> UltraProcess? {
        let owner = index.owner(of: p)
        if owner.uid != user || ownPIDs.contains(owner.pid) || isSystem(owner) { return nil }
        if owner.app == .none && owner.path.isEmpty { return nil }
        return owner
    }

    private static func groupID(_ owner: UltraProcess) -> String {
        if let bundle = owner.bundleID.nonEmpty { return bundle }
        if let label = owner.launchdLabel.nonEmpty { return "job:" + label }
        return "exe:" + executableName(owner)
    }

    private static func executableName(_ p: UltraProcess) -> String {
        p.path.split(separator: "/").last.map(String.init) ?? p.name
    }

    private static func isExtension(_ p: UltraProcess) -> Bool { p.path.contains(".appex/") }

    private static func ordered(_ groups: [FreezeGroup]) -> [FreezeGroup] {
        groups.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    private struct Draft {
        let id: String
        var name: String
        var namedBy: pid_t
        var processes: [UltraProcess] = []

        func group(of members: [UltraProcess]) -> FreezeGroup {
            FreezeGroup(id: id, name: name,
                        members: members.sorted { $0.pid < $1.pid }.map { FreezeGroup.Member(pid: $0.pid, startTime: $0.startTime) })
        }
    }

    // ── Who belongs to whom ─────────────────────────────────────────────────

    /// The list, looked up by pid, and the running apps looked up by the folder of their own bundle.
    private struct ProcessIndex {
        let byPID: [pid_t: UltraProcess]
        /// "/Applications/Foo.app/" -> the app running from it (the lowest pid when two copies run). Keyed by the
        /// INNERMOST bundle, so a helper app inside another app does not take that app's place.
        private let appByBundle: [String: UltraProcess]

        init(_ processes: [UltraProcess]) {
            byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
            var apps: [String: UltraProcess] = [:]
            for app in processes where app.app != .none {
                guard let own = bundlePrefixes(of: app.path).last else { continue }
                if let have = apps[own], have.pid <= app.pid { continue }
                apps[own] = app
            }
            appByBundle = apps
        }

        /// Follows "belongs to" until it stops changing. Every step goes to a process not yet visited, so a loop in the
        /// data (two processes each responsible for the other) ends instead of hanging.
        func owner(of p: UltraProcess) -> UltraProcess {
            var current = p
            var visited: Set<pid_t> = []
            while visited.insert(current.pid).inserted {
                let next = hop(from: current)
                if next.pid == current.pid { break }
                current = next
            }
            return current
        }

        private func hop(from c: UltraProcess) -> UltraProcess {
            // A responsible pid that has exited, is 0 or 1, or is the process itself says nothing: fall back to the parent chain.
            if let responsible = c.responsible, responsible > 1, responsible != c.pid, let next = byPID[responsible] { return next }
            var top = c
            var seen: Set<pid_t> = [c.pid]
            while top.app == .none, top.parent > 1, let up = byPID[top.parent], seen.insert(up.pid).inserted { top = up }
            // Outermost bundle first: a helper app inside a suite belongs to the suite when the suite is running, and
            // to itself when only the helper is.
            for prefix in bundlePrefixes(of: top.path) {
                if let app = appByBundle[prefix] { return app }
            }
            return top
        }
    }

    /// Every folder on the path that ends in ".app/", outermost first. A path with none has no bundle (and "" never does).
    static func bundlePrefixes(of path: String) -> [String] {
        var prefixes: [String] = []
        var from = path.startIndex
        while let found = path.range(of: ".app/", range: from..<path.endIndex) {
            prefixes.append(String(path[..<found.upperBound]))
            from = found.upperBound
        }
        return prefixes
    }

    // ── A part Anode cannot stop ────────────────────────────────────────────

    /// What the processes Anode cannot signal say about whose product they are. Stopping only the user's part of a
    /// product leaves its other part with nobody to talk to, and measured, that part spins (3.4 W became 14.4 W).
    private struct OtherUsers {
        private var bundles: Set<String> = []
        private var teams: Set<String> = []

        init(_ processes: [UltraProcess], user: uid_t) {
            for q in processes where q.uid != user {
                if let bundle = bundlePrefixes(of: q.path).first { bundles.insert(bundle) }
                if let team = q.team.nonEmpty { teams.insert(team) }
            }
        }

        /// True when one of `group` is in the same (outermost) bundle as one of theirs, or has the same signing team.
        /// A missing team never matches: the system's own code has none, and it is not one product.
        func shareAProduct(with group: [UltraProcess]) -> Bool {
            group.contains { member in
                if let bundle = bundlePrefixes(of: member.path).first, bundles.contains(bundle) { return true }
                if let team = member.team.nonEmpty, teams.contains(team) { return true }
                return false
            }
        }
    }
}

private extension Optional where Wrapped == String {
    /// nil for nil and for "".
    var nonEmpty: String? { self?.isEmpty == false ? self : nil }
}
