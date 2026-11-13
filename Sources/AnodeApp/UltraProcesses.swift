import AppKit
import CoreAudio
import CoreGraphics
import Darwin
import Foundation
import PowerKit
import Security

/// Reading, stopping and hiding processes for Ultra Low Power Mode: the thin layer that touches the system.
///
/// Everything that decides anything is somewhere else (`FreezePlanner` and the controller). This file only turns the
/// Mac into plain values (`UltraProcess`, `LoadSample`) and turns plain requests into signals, and every real call sits
/// behind a protocol so the controller is tested with fakes. The arithmetic and the joining of facts are pure static
/// functions (`assemble`, `tapOwners`, `toolLabels`, `signingTeam`, `delta`) so they are tested without the system.

// ── The protocols the controller is written against ─────────────────────────

protocol ProcessListing: AnyObject {
    /// Calls back on the main queue, once. nil when the list could not be read in full within the budget. `urgent` is for a
    /// read the owner is waiting on (asking for the mode): it runs at the priority of something the owner asked for, not of
    /// background work.
    func snapshot(urgent: Bool, completion: @escaping ([UltraProcess]?) -> Void)
}

extension ProcessListing {
    /// The sweep's and the guard's reading: background work.
    func snapshot(completion: @escaping ([UltraProcess]?) -> Void) { snapshot(urgent: false, completion: completion) }
}

protocol ProcessFreezing: AnyObject {
    /// false when the pid is gone or is not that process any more (its start time differs), or the signal was refused.
    func stop(pid: pid_t, startTime: UInt64) -> Bool
    func resume(pid: pid_t, startTime: UInt64) -> Bool
}

protocol ProcessThrottling: AnyObject {
    /// Puts the process under the background policy (all of its threads on the efficiency cores). false when the pid is gone or
    /// is not that process any more (its start time differs), or the system refused.
    func throttle(pid: pid_t, startTime: UInt64) -> Bool
    /// Lifts it, under the same checks.
    func unthrottle(pid: pid_t, startTime: UInt64) -> Bool
}

protocol AppHiding: AnyObject {
    /// Hides the app and calls back on the main queue, once, when it is hidden or `hideWait` has passed, whichever is
    /// first. `hidByUs` is true when the app was not hidden before the call and the request was taken, even if the app
    /// had not finished hiding when the wait ran out: unhiding an app that is not hidden does no harm, and leaving one
    /// Anode hid hidden does. False for an app that was hidden already (the owner's doing), that is gone, or that
    /// refused: those are not Anode's to unhide later.
    func hide(pid: pid_t, completion: @escaping (_ hidByUs: Bool) -> Void)
    func unhide(pid: pid_t)
}

/// How busy the Mac is: the whole Mac, and the owner's own processes.
struct LoadSample: Equatable {
    /// Cores' worth of work over the interval, whole Mac: 1.5 is a core and a half busy.
    var busyCores: Double
    /// Each of the owner's own processes' CPU time over the interval, in cores.
    var byProcess: [pid_t: Double]
}

protocol LoadReading: AnyObject {
    /// Since the previous call, on the main queue; nil the first time (and when nothing could be compared).
    func read(completion: @escaping (LoadSample?) -> Void)
}

// ── The process list ────────────────────────────────────────────────────────

final class LiveProcessList: ProcessListing {
    /// The whole snapshot, every system call in it included. Past this the answer is nil and the late list is dropped:
    /// a call that hangs must not hold the mode's start.
    static let budget: TimeInterval = 2.0

    /// What the kernel and `proc_pidpath` say about one process, and the responsible pid as the system answered it.
    struct KernelRow: Equatable {
        var pid: pid_t
        var parent: pid_t
        var uid: uid_t
        /// `startTime(_:)`'s number for this process: with the pid, its identity.
        var startTime: UInt64
        /// The kernel's short name (16 characters), for a process whose path cannot be read.
        var command: String
        /// "" when it cannot be read.
        var path: String
        /// Raw: nil when it was not asked (another user's process) or the call is missing; judged in `assemble`.
        var responsible: pid_t?
        /// The kernel says it was stopped (SIGSTOP, a debugger) when the table was read.
        var stopped: Bool = false
    }

    /// What `NSRunningApplication` says about a process that is an application.
    struct AppRow: Equatable {
        var kind: AppKind
        var bundleID: String?
        var name: String
    }

    /// What the code signature of a running process says.
    struct SigningFacts: Equatable {
        var identifier: String?
        var team: String?
    }

    /// How much of the snapshot's time is left. The read checks it between steps, so an overdue read stops working
    /// instead of finishing a list nobody is waiting for.
    struct ReadBudget {
        let deadline: DispatchTime
        fileprivate let abandoned: () -> Bool

        var isOver: Bool { abandoned() || DispatchTime.now() >= deadline }

        var remaining: TimeInterval {
            let left = Int64(bitPattern: deadline.uptimeNanoseconds) - Int64(bitPattern: DispatchTime.now().uptimeNanoseconds)
            return Swift.max(0, Double(left) / 1e9)
        }
    }

    private let budget: TimeInterval
    /// Instead of the system, in tests.
    private let injectedRead: ((ReadBudget) -> [UltraProcess]?)?
    private let queue = DispatchQueue(label: "dev.anode.ultra.processes", qos: .utility)
    /// Only touched on `queue`.
    private let teamCache = TeamCache()

    init(budget: TimeInterval = LiveProcessList.budget, read: ((ReadBudget) -> [UltraProcess]?)? = nil) {
        self.budget = budget
        self.injectedRead = read
    }

    func snapshot(urgent: Bool, completion: @escaping ([UltraProcess]?) -> Void) {
        let answer = OneAnswer(completion)
        let deadline = DispatchTime.now() + budget
        // The read is a serial queue's work, so a read that hangs delays the next one. Each snapshot still answers at its
        // own deadline, and a read that starts after its answer has gone does nothing.
        // One queue, because the team cache is only ever touched on it; what the owner is waiting on is given a higher priority for
        // its own run (`enforceQoS`), and the queue is not changed for the sweep's.
        let qos: DispatchQoS = urgent ? .userInitiated : .utility
        queue.async(qos: qos, flags: urgent ? .enforceQoS : []) { [self] in
            guard !answer.isDone else { return }
            let read = ReadBudget(deadline: deadline, abandoned: { answer.isDone })
            if let injectedRead {
                answer.deliver(injectedRead(read))
            } else {
                answer.deliver(readLive(read))
            }
        }
        DispatchQueue.global(qos: qos.qosClass).asyncAfter(deadline: deadline) { answer.deliver(nil) }
    }

    // ── Reading the system ──────────────────────────────────────────────────

    private func readLive(_ budget: ReadBudget) -> [UltraProcess]? {
        guard var rows = Self.kernelRows() else { return nil }
        let me = getuid()
        var apps: [pid_t: AppRow] = [:]
        var teams: [pid_t: String] = [:]
        var paths = Set<String>()
        for i in rows.indices {
            if budget.isOver { return nil }
            let pid = rows[i].pid
            rows[i].path = ProcessSampler.path(of: pid)
            paths.insert(rows[i].path)
            if let team = teamCache.team(ofPath: rows[i].path, read: { Self.signingFacts(ofPID: pid) }) { teams[pid] = team }
            // Another user's process is in the list only so the planner can see the parts of a product that are not the
            // owner's (their path and team). It is never asked what app it is, what it taps or what it listens to.
            guard rows[i].uid == me else { continue }
            rows[i].responsible = Self.responsiblePID(of: pid)
            if let app = Self.appRow(of: pid) { apps[pid] = app }
        }
        // From here on a call that cannot be answered makes the whole list nil: a mode that does not know who holds
        // the microphone, or which app owns a tap, must not stop anything.
        guard !budget.isOver, let taps = Self.eventTaps(), let audio = Self.audioInputPIDs(),
              let output = Self.launchctlList(timeout: budget.remaining), !budget.isOver else { return nil }
        teamCache.keep(only: paths)
        return Self.assemble(kernel: rows, apps: apps, tapOwners: Self.tapOwners(from: taps), audioInput: audio,
                             labels: Self.toolLabels(fromLaunchctl: output), teams: teams, user: me)
    }

    // ── Joining what was read (pure) ────────────────────────────────────────

    /// One `UltraProcess` per kernel row. The owner's own rows get what was read for them; another user's row gets its
    /// uid, path and team and nothing else, even when the inputs hold something for its pid (`app` is `.none`, no bundle,
    /// no label, no tap, no microphone, no responsible pid): the planner treats those as the facts of a process it cannot
    /// signal, and they were never read.
    static func assemble(kernel: [KernelRow], apps: [pid_t: AppRow], tapOwners: Set<pid_t>, audioInput: Set<pid_t>,
                         labels: [pid_t: String], teams: [pid_t: String], user: uid_t = getuid()) -> [UltraProcess] {
        kernel.map { row in
            let mine = row.uid == user
            let app = mine ? apps[row.pid] : nil
            // The system says "responsible" about itself, about launchd (1) and about nobody (0), and -1 when it fails;
            // none of those is another process.
            let responsible = row.responsible.flatMap { $0 > 1 && $0 != row.pid ? $0 : nil }
            return UltraProcess(
                pid: row.pid, parent: row.parent, uid: row.uid, startTime: row.startTime, path: row.path,
                responsible: mine ? responsible : nil,
                app: app?.kind ?? .none,
                bundleID: app?.bundleID.flatMap { $0.isEmpty ? nil : $0 },
                name: name(of: row, app: app),
                launchdLabel: mine ? labels[row.pid] : nil,
                team: teams[row.pid],
                ownsEventTap: mine && tapOwners.contains(row.pid),
                usesMicOrCamera: mine && audioInput.contains(row.pid),
                stopped: row.stopped)
        }
    }

    /// The app's name, else the executable's, else the kernel's short name, else the pid.
    private static func name(of row: KernelRow, app: AppRow?) -> String {
        if let name = app?.name, !name.isEmpty { return name }
        if let leaf = row.path.split(separator: "/").last { return String(leaf) }
        return row.command.isEmpty ? "pid \(row.pid)" : row.command
    }

    /// The pids that own an event tap that is enabled and not listen-only. A disabled tap delays nothing, and one that
    /// only listens cannot hold an event back; a stopped owner of any other can stall the keyboard for the whole Mac.
    static func tapOwners(from taps: [CGEventTapInformation]) -> Set<pid_t> {
        Set(taps.filter { $0.enabled && $0.options != .listenOnly }.map(\.tappingProcess))
    }

    /// pid to launchd label from `launchctl list` (columns: pid, status, label), for jobs that are running and are not an
    /// app. An app's label is `application.<bundle id>.<numbers>`: it names the app, which the bundle id already does.
    /// An anonymous one (`0x<address>.anonymous.<name>`) is dropped too, so the planner names the tool by its executable.
    /// When one process has several labels the smallest is kept, so a group's id does not change between snapshots.
    static func toolLabels(fromLaunchctl output: String) -> [pid_t: String] {
        var labels: [pid_t: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let columns = line.split(maxSplits: 2, omittingEmptySubsequences: true) { $0 == "\t" || $0 == " " }
            // "-" is a job that is not running, and the header's "PID" is not a number.
            guard columns.count == 3, let pid = pid_t(columns[0]), pid > 0 else { continue }
            let label = String(columns[2])
            if isAppLabel(label) || isAnonymousLabel(label) { continue }
            if let have = labels[pid], have <= label { continue }
            labels[pid] = label
        }
        return labels
    }

    /// The label launchd makes up for a process that checked in without a job of its own. It embeds an address, so it is
    /// different for every process and every boot: a group named by it could never be named again in a keep list.
    static func isAnonymousLabel(_ label: String) -> Bool {
        let parts = label.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[1] == "anonymous", parts[0].hasPrefix("0x"), parts[0].count > 2 else { return false }
        return parts[0].dropFirst(2).allSatisfy(\.isHexDigit)
    }

    static func isAppLabel(_ label: String) -> Bool {
        guard label.hasPrefix("application.") else { return false }
        let isNumber: (Substring) -> Bool = { part in part.allSatisfy { ("0"..."9").contains($0) } }
        return label.dropFirst("application.".count).split(separator: ".").contains(where: isNumber)
    }

    // ── The signing team ────────────────────────────────────────────────────

    /// The team that signed a process, nil for the system's own code: an identifier that begins `com.apple.`, or a
    /// signature with no team in it. (Apple's own code has none, and it is not one product.)
    static func signingTeam(_ facts: SigningFacts) -> String? {
        if facts.identifier?.hasPrefix("com.apple.") == true { return nil }
        guard let team = facts.team, !team.isEmpty else { return nil }
        return team
    }

    /// The signing team per executable path, so a snapshot does not check the same file twice.
    ///
    /// What is remembered: a team, and "this file has no team". What is not: a read that failed (the process ended
    /// between the list and the check). That is unknown, not "no team", and remembering it would lose a root daemon's
    /// team for the whole session, which is the measured way a stopped app's other half starts to spin.
    /// Not thread-safe: it belongs to the list's queue.
    final class TeamCache {
        /// Where Apple's own code is. It carries no team, so reading it only costs time: the 700 or so distinct files of a
        /// busy Mac took 1.2 s to read in full and 0.07 s with these left out, against a budget of 2 s for everything.
        /// /usr/local is not here: it is the owner's, and holds anybody's code.
        static let appleRoots = ["/System/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/bin/", "/sbin/", "/Library/Apple/"]

        /// `.some(nil)` is "read, and it has no team"; a missing key is "not read".
        private var byPath: [String: String?] = [:]

        init() {}

        func team(ofPath path: String, read: () -> SigningFacts?) -> String? {
            if path.isEmpty || Self.appleRoots.contains(where: { path.hasPrefix($0) }) { return nil }
            if let known = byPath[path] { return known }
            guard let facts = read() else { return nil }
            let team = LiveProcessList.signingTeam(facts)
            byPath[path] = .some(team)
            return team
        }

        /// Drops files that no process runs from any more, so the cache follows the Mac.
        func keep(only paths: Set<String>) {
            if byPath.count > paths.count { byPath = byPath.filter { paths.contains($0.key) } }
        }
    }

    /// Reads the signature of a RUNNING process through the Security framework. Works on a root process without root.
    private static func signingFacts(ofPID pid: pid_t) -> SigningFacts? {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess,
              let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return SigningFacts(identifier: dictionary[kSecCodeInfoIdentifier as String] as? String,
                            team: dictionary[kSecCodeInfoTeamIdentifier as String] as? String)
    }

    // ── The kernel's table and a process's start time ───────────────────────

    /// Every process of every user, from `sysctl(KERN_PROC_ALL)`; `proc_pidinfo` cannot read another user's. Path and
    /// responsible pid are filled in by the caller. nil when the table cannot be read.
    static func kernelRows() -> [KernelRow]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let stride = MemoryLayout<kinfo_proc>.stride
        // The table can grow between asking for its size and reading it: leave room, and ask again if it still does not fit.
        for _ in 0..<4 {
            var size = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
            let count = size / stride
            var table = [kinfo_proc](repeating: kinfo_proc(), count: count + count / 8 + 16)
            var got = table.count * stride
            let rc = table.withUnsafeMutableBytes { sysctl(&mib, UInt32(mib.count), $0.baseAddress, &got, nil, 0) }
            if rc == 0 { return table.prefix(got / stride).compactMap(row(from:)) }
            if errno != ENOMEM { return nil }
        }
        return nil
    }

    /// The kernel's table as plain processes, for the end of a session: pid, parent, start time, the file each runs from and the
    /// process macOS holds responsible for each of the owner's, and nothing that is a call into another process or an app (no
    /// app lookup, no signature, no `launchctl`), so it is cheap, cannot stall, and can be read on the thread that quits. What
    /// a full snapshot knows of the processes it saw is put back with `UltraThrottle.merged`. nil when the table cannot be read.
    static func processTable() -> [UltraProcess]? {
        guard var rows = kernelRows() else { return nil }
        let me = getuid()
        for i in rows.indices {
            rows[i].path = ProcessSampler.path(of: rows[i].pid)
            if rows[i].uid == me { rows[i].responsible = responsiblePID(of: rows[i].pid) }
        }
        return assemble(kernel: rows, apps: [:], tapOwners: [], audioInput: [], labels: [:], teams: [:], user: me)
    }

    private static func row(from entry: kinfo_proc) -> KernelRow? {
        var entry = entry
        let pid = entry.kp_proc.p_pid
        // Pid 0 is the kernel itself: no process to read, and never one to signal.
        guard pid > 0 else { return nil }
        let command = withUnsafeBytes(of: &entry.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return KernelRow(pid: pid, parent: entry.kp_eproc.e_ppid, uid: entry.kp_eproc.e_ucred.cr_uid,
                         startTime: startTime(of: entry), command: command, path: "", responsible: nil,
                         stopped: isStopped(status: entry.kp_proc.p_stat))
    }

    /// The kernel's process state is "stopped" (`SSTOP`): not running, and not asleep.
    static func isStopped(status: CChar) -> Bool { Int32(status) == SSTOP }

    /// The start time `LiveProcessFreezer` checks against: read again from the kernel at the moment of the signal, in
    /// the same unit the snapshot put in `UltraProcess.startTime`. nil when no such process exists.
    static func startTime(_ pid: pid_t) -> UInt64? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var entry = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        // A pid that is gone answers with success and no bytes.
        guard sysctl(&mib, UInt32(mib.count), &entry, &size, nil, 0) == 0, size >= MemoryLayout<kinfo_proc>.stride,
              entry.kp_proc.p_pid == pid else { return nil }
        return startTime(of: entry)
    }

    private static func startTime(of entry: kinfo_proc) -> UInt64 {
        let started = entry.kp_proc.p_un.__p_starttime
        return combinedStartTime(seconds: Int(started.tv_sec), microseconds: Int(started.tv_usec))
    }

    /// The one place seconds and microseconds become the number that is a process's start time.
    static func combinedStartTime(seconds: Int, microseconds: Int) -> UInt64 {
        UInt64(Swift.max(0, seconds)) * 1_000_000 + UInt64(Swift.max(0, microseconds))
    }

    // ── The facts of one of the owner's processes ───────────────────────────

    private typealias ResponsibleFunction = @convention(c) (pid_t) -> pid_t

    /// The call that says which process macOS holds responsible for another. It is not public API, so it is looked up by
    /// name, and the feature loses only this fact (the planner then follows parents) if a later macOS drops it.
    private static let responsibleFunction: ResponsibleFunction? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFunction.self)
    }()

    private static func responsiblePID(of pid: pid_t) -> pid_t? { responsibleFunction?(pid) }

    private static func appRow(of pid: pid_t) -> AppRow? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        let kind: AppKind
        switch app.activationPolicy {
        case .regular: kind = .regular
        case .accessory: kind = .accessory
        default: kind = .none
        }
        return AppRow(kind: kind, bundleID: app.bundleIdentifier, name: app.localizedName ?? "")
    }

    // ── Taps, microphone, launchd ───────────────────────────────────────────

    private static func eventTaps() -> [CGEventTapInformation]? {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success else { return nil }
        if count == 0 { return [] }
        // Room for a few taps made since the count; if even that is full, the list is not whole.
        let room = Int(count) + 16
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: room)
        var filled: UInt32 = 0
        guard CGGetEventTapList(UInt32(room), &taps, &filled) == .success, Int(filled) < room else { return nil }
        return Array(taps.prefix(Int(filled)))
    }

    /// The pids with audio input running. macOS 14 and later list audio per process; on 13 there is no such list and
    /// nobody is reported (the confirm box only names the apps).
    private static func audioInputPIDs() -> Set<pid_t>? {
        guard #available(macOS 14.0, *) else { return [] }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var listAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &listAddress, 0, nil, &size) == noErr else { return nil }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        if objects.isEmpty { return [] }
        guard AudioObjectGetPropertyData(system, &listAddress, 0, nil, &size, &objects) == noErr else { return nil }
        var pids = Set<pid_t>()
        for object in objects {
            var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var pid: pid_t = 0
            var length = UInt32(MemoryLayout<pid_t>.size)
            // An object that ended since the list was read answers with an error: it is not running anything.
            guard AudioObjectGetPropertyData(object, &address, 0, nil, &length, &pid) == noErr, pid > 0 else { continue }
            var input: UInt32 = 0
            length = UInt32(MemoryLayout<UInt32>.size)
            address.mSelector = kAudioProcessPropertyIsRunningInput
            if AudioObjectGetPropertyData(object, &address, 0, nil, &length, &input) == noErr, input != 0 { pids.insert(pid) }
        }
        return pids
    }

    /// The output of `launchctl list`, nil when it fails or has not finished in `timeout` (the child is then ended).
    /// The pipe is read as it fills, so a long list cannot block the child on a full pipe.
    private static func launchctlList(timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let collected = Collected()
        let atEnd = DispatchSemaphore(value: 0)
        let exited = DispatchSemaphore(value: 0)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                atEnd.signal()
            } else {
                collected.append(chunk)
            }
        }
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return nil
        }
        let limit = DispatchTime.now() + timeout
        guard atEnd.wait(timeout: limit) == .success, exited.wait(timeout: limit) == .success,
              process.terminationStatus == 0 else {
            pipe.fileHandleForReading.readabilityHandler = nil
            if process.isRunning { process.terminate() }
            return nil
        }
        return String(decoding: collected.data, as: UTF8.self)
    }

    private final class Collected {
        private let lock = NSLock()
        private var bytes = Data()
        func append(_ chunk: Data) { lock.lock(); bytes.append(chunk); lock.unlock() }
        var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
    }

    /// Delivers one answer on the main queue: whichever of the list and the time-out comes first. The other is dropped.
    private final class OneAnswer {
        private let lock = NSLock()
        private var delivered = false
        private let completion: ([UltraProcess]?) -> Void

        init(_ completion: @escaping ([UltraProcess]?) -> Void) { self.completion = completion }

        var isDone: Bool { lock.lock(); defer { lock.unlock() }; return delivered }

        func deliver(_ result: [UltraProcess]?) {
            lock.lock()
            let first = !delivered
            delivered = true
            lock.unlock()
            guard first else { return }
            DispatchQueue.main.async { self.completion(result) }
        }
    }
}

// ── Stopping and continuing ─────────────────────────────────────────────────

final class LiveProcessFreezer: ProcessFreezing {
    private let startTimeOf: (pid_t) -> UInt64?
    private let signal: (pid_t, Int32) -> Int32

    init(startTimeOf: @escaping (pid_t) -> UInt64? = LiveProcessList.startTime,
         signal: @escaping (pid_t, Int32) -> Int32 = kill) {
        self.startTimeOf = startTimeOf
        self.signal = signal
    }

    func stop(pid: pid_t, startTime: UInt64) -> Bool { send(SIGSTOP, to: pid, startTime: startTime) }

    func resume(pid: pid_t, startTime: UInt64) -> Bool { send(SIGCONT, to: pid, startTime: startTime) }

    /// Signals the process only if it is still the one the snapshot saw. Between the check and the signal a process can
    /// still end and its pid be reused; that window is a few microseconds and cannot be closed from outside the kernel.
    private func send(_ sig: Int32, to pid: pid_t, startTime: UInt64) -> Bool {
        // Never a pid that means something else to kill(2): 0 is Anode's own process group, -1 is every process the owner
        // runs. Pid 1 is launchd, and Anode itself is never stopped (a stopped Anode could not continue anything).
        guard pid > 1, pid != getpid() else { return false }
        guard startTimeOf(pid) == startTime else { return false }
        return signal(pid, sig) == 0
    }
}

// ── The efficiency cores ────────────────────────────────────────────────────

/// The system's background policy on a process: on Apple silicon it confines all of the process's threads to the efficiency
/// cores (measured: four busy threads cost 27.4 W normally and 5.0 W this way), and slows its disk and network use too.
final class LiveProcessThrottler: ProcessThrottling {
    private let startTimeOf: (pid_t) -> UInt64?
    private let setPolicy: (pid_t, Bool) -> Bool

    /// `setPolicy` is the system's call; tests replace it, and nothing in the test target changes a real process's policy.
    init(startTimeOf: @escaping (pid_t) -> UInt64? = LiveProcessList.startTime,
         setPolicy: @escaping (pid_t, Bool) -> Bool = LiveProcessThrottler.setBackground) {
        self.startTimeOf = startTimeOf
        self.setPolicy = setPolicy
    }

    // Nothing is read before the policy is set, and that is deliberate. Asked about another process, the system answers "not in the
    // background" whatever its state; the task priority does tell, but more than half of the owner's processes already read as
    // background at rest (idle services), so it cannot say who put one there. And a process that put ITSELF in the background keeps
    // that setting when this mode lifts its own, so setting and lifting never undo what a process chose for itself. So every
    // process is set, named on the record, and lifted at the end.
    func throttle(pid: pid_t, startTime: UInt64) -> Bool { change(pid, startTime, to: true) }

    func unthrottle(pid: pid_t, startTime: UInt64) -> Bool { change(pid, startTime, to: false) }

    /// Changes the policy only of the process the snapshot saw, as the freezer signals only that one. Between the check and the
    /// call a process can still end and its pid be reused; that window is a few microseconds and cannot be closed from outside
    /// the kernel.
    private func change(_ pid: pid_t, _ startTime: UInt64, to on: Bool) -> Bool {
        // The pids the freezer never touches: 0 and below mean something else to the system, 1 is launchd, and Anode itself is
        // never slowed (it is the one that lifts the policy again).
        guard pid > 1, pid != getpid() else { return false }
        guard startTimeOf(pid) == startTime else { return false }
        return setPolicy(pid, on)
    }

    static func setBackground(_ pid: pid_t, _ on: Bool) -> Bool {
        guard let who = id_t(exactly: pid) else { return false }
        return setpriority(PRIO_DARWIN_PROCESS, who, on ? PRIO_DARWIN_BG : 0) == 0
    }

    /// Detected from the processor's performance levels, not from a model list. A Mac that does not say has none.
    static var hasEfficiencyCores: Bool {
        var levels: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.nperflevels", &levels, &size, nil, 0) == 0 else { return false }
        return UltraThrottle.hasEfficiencyCores(performanceLevels: Int(levels))
    }
}

// ── Hiding ──────────────────────────────────────────────────────────────────

/// Hides an app before it is stopped. Measured: stopped at once, the window stays on screen as a dead picture; hidden
/// first, no window is left (`isHidden` was true within 0.2 s).
final class LiveAppHider: AppHiding {
    /// The longest wait for `isHidden`, after which the app is stopped either way.
    static let hideWait: TimeInterval = 1.0
    static let pollInterval: TimeInterval = 0.05

    private let hideApp: (pid_t) -> Bool
    private let isHidden: (pid_t) -> Bool
    private let unhideApp: (pid_t) -> Void
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void

    /// The closures are the system; tests replace all four so no app is ever hidden, and nothing waits for real.
    /// `hideApp` returns false when there is no such app (it has ended); the others are called on the main thread.
    init(hideApp: @escaping (pid_t) -> Bool = { NSRunningApplication(processIdentifier: $0)?.hide() ?? false },
         isHidden: @escaping (pid_t) -> Bool = { NSRunningApplication(processIdentifier: $0)?.isHidden ?? true },
         unhideApp: @escaping (pid_t) -> Void = { _ = NSRunningApplication(processIdentifier: $0)?.unhide() },
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         }) {
        self.hideApp = hideApp
        self.isHidden = isHidden
        self.unhideApp = unhideApp
        self.schedule = schedule
    }

    func hide(pid: pid_t, completion: @escaping (Bool) -> Void) {
        onMain { [self] in
            // Hidden already (or no such app, which reads as hidden): the owner's doing, or nothing to do.
            if isHidden(pid) { completion(false); return }
            // Refused, or the app ended between the look and the call: nothing to wait for.
            guard hideApp(pid) else { completion(false); return }
            check(pid, left: Int((Self.hideWait / Self.pollInterval).rounded()), completion: completion)
        }
    }

    func unhide(pid: pid_t) { onMain { [self] in unhideApp(pid) } }

    /// One check now, then one every `pollInterval` until it is hidden or `left` waits are used up. `completion` is
    /// called exactly once, whichever way it ends. True either way: the request was taken, so whatever the app does
    /// next is Anode's doing.
    private func check(_ pid: pid_t, left: Int, completion: @escaping (Bool) -> Void) {
        if isHidden(pid) || left == 0 { completion(true); return }
        schedule(Self.pollInterval) { [self] in check(pid, left: left - 1, completion: completion) }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}

// ── Load ────────────────────────────────────────────────────────────────────

final class LiveLoadReader: LoadReading {
    /// The kernel's cumulative CPU tick counters for the whole Mac (they wrap at 32 bits).
    struct HostTicks: Equatable {
        var user: UInt32
        var system: UInt32
        var idle: UInt32
        var nice: UInt32
    }

    /// Everything one read takes: the whole Mac's ticks, and each readable process's CPU seconds since it started.
    struct Reading {
        var ticks: HostTicks
        var cores: Int
        /// `mach_absolute_time()` when the reading was complete: the same clock as a process's start time (measured: the
        /// sampler's `startAbsTime` agrees with it, and not with `mach_continuous_time()`, which also counts sleep).
        var takenAt: UInt64
        /// Keyed by pid AND start time: a pid that was reused is another process.
        var cpuSeconds: [ProcessKey: Double]
    }

    private let queue = DispatchQueue(label: "dev.anode.ultra.load", qos: .utility)
    /// Both only touched on `queue`.
    private let identities = ProcessSampler.IdentityCache()
    private var previous: (reading: Reading, at: UInt64)?

    init() {}

    func read(completion: @escaping (LoadSample?) -> Void) {
        queue.async { [self] in
            let sample = take()
            DispatchQueue.main.async { completion(sample) }
        }
    }

    private func take() -> LoadSample? {
        guard let ticks = Self.hostTicks() else { return nil }
        // Uptime, not the wall clock: it does not jump, and the counters do not run while the Mac sleeps either.
        let at = DispatchTime.now().uptimeNanoseconds
        // proc_pid_rusage reads only the owner's own processes (the rest answer EPERM), which is the set that can be stopped.
        let sweep = ProcessSampler.sweep(reusing: identities)
        var seconds: [ProcessKey: Double] = [:]
        seconds.reserveCapacity(sweep.processes.count)
        for (key, process) in sweep.processes {
            // The sampler's "_ns" fields are mach time units: MachTime converts them (dividing by 1e9 reads 41.7 times low).
            seconds[key] = MachTime.seconds(units: process.userTime_ns &+ process.systemTime_ns)
        }
        let current = Reading(ticks: ticks, cores: MachTime.activeCores, takenAt: mach_absolute_time(), cpuSeconds: seconds)
        defer { previous = (current, at) }
        guard let before = previous else { return nil }
        return Self.delta(previous: before.reading, current: current, elapsed: Double(at &- before.at) / 1e9)
    }

    /// The load between two readings `elapsed` seconds apart. nil when no time or no tick has passed.
    static func delta(previous: Reading, current: Reading, elapsed: TimeInterval) -> LoadSample? {
        guard elapsed > 0 else { return nil }
        // Wrapping subtraction: a counter that passed the top of its 32 bits is not a huge negative step.
        let user = Double(current.ticks.user &- previous.ticks.user)
        let system = Double(current.ticks.system &- previous.ticks.system)
        let nice = Double(current.ticks.nice &- previous.ticks.nice)
        let idle = Double(current.ticks.idle &- previous.ticks.idle)
        let total = user + system + nice + idle
        guard total > 0 else { return nil }
        let busyCores = (user + system + nice) / total * Double(current.cores)

        var byProcess: [pid_t: Double] = [:]
        byProcess.reserveCapacity(current.cpuSeconds.count)
        for (key, now) in current.cpuSeconds {
            let before: Double
            if let seen = previous.cpuSeconds[key] {
                before = seen
            } else if key.startAbsTime > previous.takenAt {
                // Not there before, and started after that reading (or its pid was reused): all the CPU time it has is
                // this interval's, so it counts from zero.
                before = 0
            } else {
                // Older than the last reading but missing from it (a read of it failed once): its lifetime of CPU time is
                // not this interval's, and counted as if it were it would look like a process burning hundreds of cores.
                // Left out for this interval; the next one has it.
                continue
            }
            byProcess[key.pid] = Swift.max(0, now - before) / elapsed
        }
        return LoadSample(busyCores: busyCores, byProcess: byProcess)
    }

    private static func hostTicks() -> HostTicks? {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info_data_t()
        let rc = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard rc == KERN_SUCCESS else { return nil }
        return HostTicks(user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
    }
}
