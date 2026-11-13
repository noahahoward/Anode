import Foundation

/// What Ultra Low Power Mode knows about one process, as plain values.
///
/// The system is read somewhere else (the live process list) and turned into these; the rule that sorts them into
/// kept, frozen and left running (`FreezePlanner`) never touches the Mac, so every case of it is tested with a made-up
/// list.

/// How macOS lists a process as an application.
public enum AppKind: Equatable {
    /// An app with a Dock icon.
    case regular
    /// An app with no Dock icon: a menu bar app, an agent that has a bundle.
    case accessory
    /// Not an app macOS lists: a tool, a helper, a daemon.
    case none
}

public struct UltraProcess: Equatable {
    public var pid: pid_t
    public var parent: pid_t
    public var uid: uid_t
    /// With the pid, the identity of a process: a recycled pid has another start time.
    public var startTime: UInt64
    /// "" when it cannot be read.
    public var path: String
    /// The process macOS holds responsible for this one; nil when unknown or when it is itself.
    public var responsible: pid_t?
    public var app: AppKind
    public var bundleID: String?
    /// The app's name, else the executable's.
    public var name: String
    public var launchdLabel: String?
    /// The signing team; nil for the system's own code and for unsigned code.
    public var team: String?
    /// Owns an ENABLED event tap that is not listen-only (a disabled tap does not count): stopping it can stall input.
    public var ownsEventTap: Bool
    public var usesMicOrCamera: Bool
    /// Already stopped (SIGSTOP or a debugger) when it was read: not Anode's to stop, and not Anode's to continue.
    public var stopped: Bool

    public init(pid: pid_t, parent: pid_t, uid: uid_t, startTime: UInt64, path: String, responsible: pid_t? = nil,
                app: AppKind = .none, bundleID: String? = nil, name: String, launchdLabel: String? = nil,
                team: String? = nil, ownsEventTap: Bool = false, usesMicOrCamera: Bool = false, stopped: Bool = false) {
        self.pid = pid
        self.parent = parent
        self.uid = uid
        self.startTime = startTime
        self.path = path
        self.responsible = responsible
        self.app = app
        self.bundleID = bundleID
        self.name = name
        self.launchdLabel = launchdLabel
        self.team = team
        self.ownsEventTap = ownsEventTap
        self.usesMicOrCamera = usesMicOrCamera
        self.stopped = stopped
    }
}

/// Everything that belongs to one app, or to one background tool, and is stopped or kept as a whole.
public struct FreezeGroup: Equatable {
    /// The app's bundle id, else "job:" and its launchd label, else "exe:" and its executable's name.
    public var id: String
    /// What the owner reads in the confirm box and the menu.
    public var name: String
    /// Sorted by pid.
    public var members: [Member]

    public struct Member: Equatable {
        public var pid: pid_t
        public var startTime: UInt64

        public init(pid: pid_t, startTime: UInt64) {
            self.pid = pid
            self.startTime = startTime
        }
    }

    public init(id: String, name: String, members: [Member]) {
        self.id = id
        self.name = name
        self.members = members
    }
}

/// The three piles. Whatever is in none of them is never touched.
public struct FreezePlan: Equatable {
    /// The front app, the apps on the keep list and the apps using the microphone or camera: what the confirm box names.
    public var kept: [FreezeGroup]
    public var frozen: [FreezeGroup]
    /// Would be frozen, but has a part Anode cannot stop; stopping the rest makes that part spin.
    public var leftRunning: [FreezeGroup]

    public init(kept: [FreezeGroup], frozen: [FreezeGroup], leftRunning: [FreezeGroup]) {
        self.kept = kept
        self.frozen = frozen
        self.leftRunning = leftRunning
    }
}
