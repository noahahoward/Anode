import Darwin
import Foundation

/// The per-process facts Activity Monitor shows in its inspector, and the ability to
/// quit a process.
///
/// All of it comes from `proc_pidinfo`, unprivileged, for processes owned by the
/// current user — the same ~63% boundary as the energy counters. Cross-uid processes
/// return nil rather than partial data.
///
/// NOT available, and deliberately not faked:
///   • "Recent hangs" — Apple's private hang tracer, no public equivalent.
///   • Shared / private memory split — needs task_for_pid or a full VM region walk,
///     both privileged. Real and virtual size are available and are shown instead.
///   • Mach port count — needs task_for_pid.
public struct ProcessDetails {
    public let pid: pid_t
    public let name: String
    public let executablePath: String
    public let parentPID: pid_t
    public let parentName: String?
    public let uid: uid_t
    public let userName: String?
    public let processGroup: pid_t
    public let started: Date?

    /// Resident (real) and virtual size, in bytes.
    public let residentSize: UInt64
    public let virtualSize: UInt64

    public let threadCount: Int
    public let runningThreads: Int
    public let openFiles: Int
    public let contextSwitches: UInt64
    public let faults: UInt64
    public let pageIns: UInt64
    public let copyOnWriteFaults: UInt64
    public let machMessagesSent: UInt64
    public let machMessagesReceived: UInt64
    public let unixSyscalls: UInt64
    public let machSyscalls: UInt64

    /// True when this process belongs to the current user, and therefore can be
    /// signalled. Root-owned processes report false rather than offering a Quit
    /// button that is guaranteed to fail.
    public var isOwnedByCurrentUser: Bool { uid == getuid() }
}

public enum ProcessInspector {

    public static func details(for pid: pid_t) -> ProcessDetails? {
        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize else { return nil }

        var task = proc_taskinfo()
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
        let haveTask = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize

        let path = ProcessSampler.path(of: pid)
        let start = TimeInterval(bsd.pbi_start_tvsec) + TimeInterval(bsd.pbi_start_tvusec) / 1e6

        return ProcessDetails(
            pid: pid,
            name: ProcessSampler.name(fromPath: path, pid: pid),
            executablePath: path,
            parentPID: pid_t(bsd.pbi_ppid),
            parentName: bsd.pbi_ppid > 0
                ? ProcessSampler.name(fromPath: ProcessSampler.path(of: pid_t(bsd.pbi_ppid)),
                                      pid: pid_t(bsd.pbi_ppid))
                : nil,
            uid: bsd.pbi_uid,
            userName: userName(for: bsd.pbi_uid),
            processGroup: pid_t(bsd.pbi_pgid),
            started: bsd.pbi_start_tvsec > 0 ? Date(timeIntervalSince1970: start) : nil,
            residentSize: haveTask ? task.pti_resident_size : 0,
            virtualSize: haveTask ? task.pti_virtual_size : 0,
            threadCount: haveTask ? Int(task.pti_threadnum) : 0,
            runningThreads: haveTask ? Int(task.pti_numrunning) : 0,
            openFiles: Int(bsd.pbi_nfiles),
            contextSwitches: haveTask ? UInt64(task.pti_csw) : 0,
            faults: haveTask ? UInt64(task.pti_faults) : 0,
            pageIns: haveTask ? UInt64(task.pti_pageins) : 0,
            copyOnWriteFaults: haveTask ? UInt64(task.pti_cow_faults) : 0,
            machMessagesSent: haveTask ? UInt64(task.pti_messages_sent) : 0,
            machMessagesReceived: haveTask ? UInt64(task.pti_messages_received) : 0,
            unixSyscalls: haveTask ? UInt64(task.pti_syscalls_unix) : 0,
            machSyscalls: haveTask ? UInt64(task.pti_syscalls_mach) : 0)
    }

    private static var userCache: [uid_t: String] = [:]
    private static let cacheLock = NSLock()

    private static func userName(for uid: uid_t) -> String? {
        cacheLock.lock()
        if let hit = userCache[uid] { cacheLock.unlock(); return hit }
        cacheLock.unlock()

        guard let pw = getpwuid(uid) else { return nil }
        let name = String(cString: pw.pointee.pw_name)

        cacheLock.lock(); userCache[uid] = name; cacheLock.unlock()
        return name
    }
}

/// Quitting a process.
///
/// Two levels, matching what people expect from Activity Monitor:
///
///   • **Quit** asks politely. For a GUI application that is a Quit Apple Event, so
///     the app can prompt about unsaved work; for anything else it is SIGTERM, which
///     a process can catch and clean up after. Either way the process decides when.
///   • **Force Quit** is SIGKILL. It cannot be caught, blocked or deferred, so
///     unsaved work is simply lost. That is why it is a separate call and why the
///     caller is expected to confirm first.
public enum ProcessControl {

    public enum Result: Equatable {
        case requested          // asked politely; the process may still refuse
        case killed
        case notPermitted       // cross-uid: needs the privileged helper
        case noSuchProcess
        case failed(Int32)

        public var message: String {
            switch self {
            case .requested:     return "Quit requested"
            case .killed:        return "Force quit"
            case .notPermitted:  return "Not permitted — this process belongs to another user"
            case .noSuchProcess: return "That process has already exited"
            case .failed(let e): return "Failed (errno \(e))"
            }
        }
    }

    /// Never signal ourselves by accident: quitting the monitor from inside its own
    /// process list is almost certainly a misclick, and the app cannot report the
    /// outcome of its own death.
    public static func isSelf(_ pid: pid_t) -> Bool { pid == getpid() }

    public static func quit(pid: pid_t) -> Result {
        guard !isSelf(pid) else { return .notPermitted }

        // A GUI app gets the Apple Event, which lets it save and prompt. SIGTERM
        // would skip all of that.
        if let app = NSRunningApplicationShim.application(pid: pid) {
            return app.terminate() ? .requested : .failed(0)
        }
        return signal(pid, SIGTERM)
    }

    public static func forceQuit(pid: pid_t) -> Result {
        guard !isSelf(pid) else { return .notPermitted }
        if let app = NSRunningApplicationShim.application(pid: pid) {
            return app.forceTerminate() ? .killed : .failed(0)
        }
        return signal(pid, SIGKILL) == .requested ? .killed : signal(pid, SIGKILL)
    }

    private static func signal(_ pid: pid_t, _ sig: Int32) -> Result {
        guard kill(pid, sig) == 0 else {
            switch errno {
            case EPERM:  return .notPermitted
            case ESRCH:  return .noSuchProcess
            default:     return .failed(errno)
            }
        }
        return sig == SIGKILL ? .killed : .requested
    }
}

/// Keeps PowerKit free of an AppKit dependency while still using
/// NSRunningApplication when it is available.
enum NSRunningApplicationShim {
    static func application(pid: pid_t) -> RunningApp? {
        #if canImport(AppKit)
        return RunningApp(pid: pid)
        #else
        return nil
        #endif
    }
}

#if canImport(AppKit)
import AppKit

struct RunningApp {
    private let app: NSRunningApplication
    init?(pid: pid_t) {
        guard let a = NSRunningApplication(processIdentifier: pid) else { return nil }
        self.app = a
    }
    func terminate() -> Bool { app.terminate() }
    func forceTerminate() -> Bool { app.forceTerminate() }
}
#else
struct RunningApp {
    init?(pid: pid_t) { return nil }
    func terminate() -> Bool { false }
    func forceTerminate() -> Bool { false }
}
#endif
