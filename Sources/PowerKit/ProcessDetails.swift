import Darwin
import Foundation
import Security

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

/// The one predicate that decides whether this app can signal a pid.
///
/// It exists as a named function with one implementation because two features now
/// depend on the answer and they must not be able to drift: `ProcessActions.plan`
/// decides whether to ENABLE a Quit button, and `QuitSafety` decides what to TELL
/// the user about that button. A "safe to quit" line that disagrees with the
/// button beside it is worse than either being wrong alone — it makes the app look
/// like it is hiding something.
public enum ProcessSignalability {

    /// - Parameters:
    ///   - selfPID: our own pid, which is never signalable. Quitting the monitor
    ///     from inside its own process list is almost certainly a misclick, and
    ///     the app cannot report the outcome of its own death.
    ///   - currentUID: cross-uid `kill(2)` fails with EPERM for an unprivileged
    ///     process, so a different uid is a hard no rather than a maybe.
    ///
    /// The `pid > 0` term is not defensive tidiness. `kill(2)` reads non-positive
    /// pids as BROADCASTS — 0 is our own process group, -1 is every process this
    /// user may signal — so a plan built around one of those would not be a plan
    /// to quit a row, it would be a plan to take down the session. pid 0 is
    /// `kernel_task`, which appears in process listings like anything else.
    public static func canSignal(pid: pid_t, uid: uid_t,
                                 currentUID: uid_t = getuid(),
                                 selfPID: pid_t = getpid()) -> Bool {
        pid > 0 && pid != selfPID && uid == currentUID
    }
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

// ─────────────────────────────────────────────────────────────────────────────
// MARK: What is this process?

/// Where a binary lives — most of the answer to "is this Apple's".
///
/// The distinctions here are about WHO COULD HAVE WRITTEN THE FILE, not about
/// tidiness. `/System` is a cryptographically sealed volume that no installer,
/// root shell or malware can modify while the system is running; `/usr/local` is
/// the one path under `/usr` that SIP leaves writable, which is why it is grouped
/// with `/Library` rather than with `/usr`.
public enum InstallDomain: Equatable, Sendable {
    /// The sealed system volume. Only a macOS install or update writes here.
    case sealedSystem
    /// `/usr`, `/bin`, `/sbin` — SIP-protected system binaries.
    case systemBinaries
    /// `/Applications` — installed for every user on this Mac.
    case applications
    /// `/Library`, `/usr/local`, `/opt` — written by an administrator or an
    /// installer package, not by macOS itself.
    case administrator
    /// Inside the user's home directory.
    case userHome
    case elsewhere
    /// No executable path — see `ProcessInspector.details`, which cannot read one
    /// for the kernel.
    case unknown

    /// Phrased as a clause so `ProcessExplanation.headline` can assemble a
    /// sentence out of parts without knowing what any of them will say.
    public var text: String {
        switch self {
        case .sealedSystem:   return "in the sealed system volume, which only macOS itself writes to"
        case .systemBinaries: return "in the SIP-protected system binaries"
        case .applications:   return "in /Applications, installed for every user"
        case .administrator:  return "in a location an administrator or an installer writes to"
        case .userHome:       return "in this user's home folder"
        case .elsewhere:      return "outside the usual install locations"
        case .unknown:        return "with no file on disk"
        }
    }

    /// Pure so it can be driven with paths no test machine has to contain.
    ///
    /// The firmlink strip comes first and is not cosmetic: on an APFS boot volume
    /// group the user's data is reachable BOTH as `/Users/x` and as
    /// `/System/Volumes/Data/Users/x`, and `proc_pidpath` returns the second form
    /// often enough that classifying on the raw prefix would file a user's own
    /// download under "sealed system volume" — the single most misleading answer
    /// this function could give.
    public static func of(path: String, home: String = NSHomeDirectory()) -> InstallDomain {
        guard !path.isEmpty else { return .unknown }
        let firmlink = "/System/Volumes/Data"
        if path.hasPrefix(firmlink + "/") {
            return of(path: String(path.dropFirst(firmlink.count)), home: home)
        }
        if path.hasPrefix("/usr/local/") || path.hasPrefix("/opt/") { return .administrator }
        if path.hasPrefix("/System/") { return .sealedSystem }
        if ["/usr/", "/bin/", "/sbin/"].contains(where: path.hasPrefix) { return .systemBinaries }
        if path.hasPrefix("/Applications/") { return .applications }
        if path.hasPrefix("/Library/") { return .administrator }
        if !home.isEmpty, path.hasPrefix(home + "/") { return .userHome }
        return .elsewhere
    }
}

/// What KIND of thing the process is, read off the bundle that wraps it.
///
/// Every case here is decided by a directory suffix that macOS itself defines and
/// loads by — `.appex` is what ExtensionKit loads, `.dext` is what DriverKit
/// loads. So this is a structural fact, not a classification we invented, and it
/// answers "why is it running" for the on-demand cases: an app extension is
/// running because something asked for its extension point.
public enum ProcessForm: Equatable, Sendable {
    case kernel
    case application
    case appExtension
    case xpcService
    case driverExtension
    case systemExtension
    /// A plain executable that lives inside a `.framework` — how a fair number of
    /// Apple's services ship, `WindowServer` inside `SkyLight.framework` among them.
    case frameworkHelper
    case executable

    public var text: String {
        switch self {
        case .kernel:           return "The kernel"
        case .application:      return "An application"
        case .appExtension:     return "An app extension"
        case .xpcService:       return "An XPC service"
        case .driverExtension:  return "A driver extension"
        case .systemExtension:  return "A system extension"
        case .frameworkHelper:  return "A helper inside a framework"
        case .executable:       return "A command-line executable"
        }
    }
}

/// The bundle structure around an executable path.
///
/// Two different questions, and the answers differ constantly:
///   • WHAT IS IT — the INNERMOST bundle. `…/Brave Browser Helper.app/Contents/
///     MacOS/Brave Browser Helper` is an application in its own right.
///   • WHAT IS IT PART OF — the OUTERMOST `.app` or `.framework`. That one is
///     Brave Browser, and it is the row the user actually recognises.
///
/// `AppResolver` already takes the outermost `.app` and only that, because the
/// process TABLE must roll fifteen helpers into one row. This view is the
/// opposite: the inspector exists to say what an individual helper is, so it
/// needs both ends of the path and keeps them apart.
public struct BundleShape: Equatable, Sendable {
    public let form: ProcessForm
    /// The innermost bundle directory, nil for a bare executable.
    public let bundlePath: String?
    /// The outermost `.app`/`.framework` this sits inside, when that is a
    /// DIFFERENT bundle from `bundlePath`. nil when the process is that thing
    /// itself, so "part of" is never a process pointing at itself.
    public let containerPath: String?

    public var containerName: String? {
        containerPath.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
    }

    /// Suffixes macOS itself loads by, innermost match wins.
    private static let forms: [(suffix: String, form: ProcessForm)] = [
        (".appex", .appExtension),
        (".dext", .driverExtension),
        (".systemextension", .systemExtension),
        (".xpc", .xpcService),
        (".app", .application),
        (".framework", .frameworkHelper),
    ]

    /// Pure: paths in, structure out, no filesystem access.
    public static func of(path: String) -> BundleShape {
        let parts = path.components(separatedBy: "/")

        // Innermost first — scanning from the executable back towards the root
        // is what makes `X.appex` inside `Y.app` report as an app extension
        // rather than as the application it is bundled with.
        var inner: (index: Int, form: ProcessForm)?
        for i in stride(from: parts.count - 1, through: 0, by: -1) {
            if let m = forms.first(where: { parts[i].hasSuffix($0.suffix) }) {
                inner = (i, m.form); break
            }
        }
        guard let inner else {
            return BundleShape(form: .executable, bundlePath: nil, containerPath: nil)
        }

        let bundlePath = parts[0...inner.index].joined(separator: "/")
        // Outermost wrapper: an `.app` if there is one, otherwise a `.framework`.
        // `.app` wins because that is the thing with a Dock icon and a name the
        // user knows.
        let outer = parts.firstIndex { $0.hasSuffix(".app") }
            ?? parts.firstIndex { $0.hasSuffix(".framework") }
        let containerPath = outer.flatMap { o -> String? in
            o < inner.index ? parts[0...o].joined(separator: "/") : nil
        }
        return BundleShape(form: inner.form, bundlePath: bundlePath, containerPath: containerPath)
    }
}

/// The strings the author put in `Info.plist`.
public struct BundleFacts: Equatable, Sendable {
    public let identifier: String?
    public let displayName: String?
    public let copyright: String?
    /// The extension point a `.appex` plugs into — the closest thing to a
    /// machine-readable "why is this running": macOS started it because something
    /// asked for this point.
    public let extensionPoint: String?
    /// `CFBundleExecutable` — the bundle's MAIN binary.
    ///
    /// Load-bearing, not decoration. An app bundle contains many executables that
    /// are not it: `/Applications/Xcode.app/…/usr/bin/xctest` is inside Xcode.app,
    /// and without this field the display name lookup reported that `xctest` is
    /// "Xcode" — a bundle's name describes the bundle's own binary and nothing
    /// else underneath it. Found by running the explainer against the test
    /// runner's own pid.
    public let executableName: String?

    public init(identifier: String?, displayName: String?, copyright: String?,
                extensionPoint: String?, executableName: String? = nil) {
        self.identifier = identifier
        self.displayName = displayName
        self.copyright = copyright
        self.extensionPoint = extensionPoint
        self.executableName = executableName
    }

    static let empty = BundleFacts(identifier: nil, displayName: nil,
                                   copyright: nil, extensionPoint: nil)

    /// Read directly rather than through `Bundle(path:)`: a `.dext` is a FLAT
    /// bundle with `Info.plist` at its top level while an `.app` nests it under
    /// `Contents/`, and `Bundle` also caches instances process-wide, which is not
    /// wanted for a path we may be looking at once.
    static func read(bundlePath: String) -> BundleFacts {
        let candidates = ["\(bundlePath)/Contents/Info.plist", "\(bundlePath)/Info.plist"]
        guard let data = candidates.lazy.compactMap({ FileManager.default.contents(atPath: $0) }).first,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let d = plist as? [String: Any] else { return .empty }

        // ExtensionKit (`EXAppExtensionAttributes`) and the older NSExtension
        // style are both in use on this machine — `TGOnDeviceInferenceProviderService`
        // is the first, a Share menu extension the second.
        let ex = (d["EXAppExtensionAttributes"] as? [String: Any])?["EXExtensionPointIdentifier"]
        let ns = (d["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"]

        return BundleFacts(
            identifier: d["CFBundleIdentifier"] as? String,
            // Display name first: it is the localized, user-facing string when the
            // author bothered to set one.
            displayName: (d["CFBundleDisplayName"] as? String) ?? (d["CFBundleName"] as? String),
            copyright: d["NSHumanReadableCopyright"] as? String,
            extensionPoint: (ex as? String) ?? (ns as? String),
            executableName: d["CFBundleExecutable"] as? String)
    }
}

/// Who signed the binary — VERIFIED, not read off a string.
///
/// The distinction matters enough to pay for. `SecCodeCopySigningInformation`
/// will happily hand back a certificate whose subject says "macOS Software
/// Signing"; only `SecStaticCodeCheckValidity` against a requirement actually
/// checks the chain and the code hashes. Telling a user "this is Apple's" on the
/// strength of an unverified string would be precisely the kind of claim this
/// project refuses to make about a sensor, and the consequence here is worse.
///
/// MEASURED on this machine, per binary, first call only (the Security framework
/// caches inside the `SecStaticCode`): bluetoothd 16 ms, duetexpertd 1 ms, Brave
/// Browser 11 ms, Finder 69 ms. `ProcessExplainer` caches by path on top of that,
/// so a selected row pays once.
public enum CodeOrigin: Equatable, Sendable {
    /// Apple's own OS signing chain — satisfies `anchor apple`. This is a macOS
    /// component, not a third-party app that happens to be notarized.
    case apple
    case macAppStore
    case developerID(String)
    /// Signed with no certificate at all. Valid, and it proves nothing about who
    /// made it — a locally built binary looks exactly like this. So does ours.
    case adHoc
    case unsigned
    /// A valid signature that matches none of the above.
    case otherAuthority(String)
    /// The file could not be read — it may have been deleted since it launched.
    case unknown

    /// A clause, for the same reason as `InstallDomain.text`. The ad-hoc and
    /// unsigned cases deliberately do NOT read "signed by nobody": an ad-hoc
    /// signature is a real, valid signature that simply names no party, and
    /// saying it is unsigned would be a different — and wrong — accusation.
    public var text: String {
        switch self {
        case .apple:                 return "signed by Apple as part of macOS"
        case .macAppStore:           return "signed for the Mac App Store"
        case .developerID(let who):  return "signed by \(who) and notarized by Apple"
        case .adHoc:                 return "signed ad-hoc, so it names no developer"
        case .unsigned:              return "not signed at all"
        case .otherAuthority(let a): return "signed by \(a)"
        case .unknown:               return "of unreadable origin"
        }
    }

    public var isApple: Bool { self == .apple }
}

enum CodeSignature {

    /// Apple's documented requirement strings. Compiled once — building one is
    /// not free and the answer never changes.
    private static let appleAnchor = requirement("anchor apple")
    private static let developerID = requirement(
        "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists "
        + "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists")
    private static let appStore = requirement(
        "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists")

    private static func requirement(_ s: String) -> SecRequirement? {
        var r: SecRequirement?
        return SecRequirementCreateWithString(s as CFString, [], &r) == errSecSuccess ? r : nil
    }

    static func origin(ofExecutableAt path: String) -> CodeOrigin {
        guard !path.isEmpty else { return .unknown }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code)
                == errSecSuccess, let code else { return .unknown }

        var raw: CFDictionary?
        let status = SecCodeCopySigningInformation(
            code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw)
        // errSecCSUnsigned. Named rather than compared against the symbol because
        // the symbol is not exposed to Swift.
        if status == -67062 { return .unsigned }
        guard status == errSecSuccess else { return .unknown }
        let info = raw as? [String: Any] ?? [:]

        // Ad-hoc is checked before the requirements: an ad-hoc signature has no
        // chain, so every anchored requirement fails and the fall-through would
        // report "some other authority" for a binary that names no authority at
        // all. `kSecCodeSignatureAdhoc` is 0x2.
        if let flags = info["flags"] as? UInt32, flags & 0x2 != 0 { return .adHoc }

        if let r = appleAnchor, SecStaticCodeCheckValidity(code, [], r) == errSecSuccess {
            return .apple
        }
        if let r = developerID, SecStaticCodeCheckValidity(code, [], r) == errSecSuccess {
            return .developerID(authority(info) ?? "a Developer ID team")
        }
        if let r = appStore, SecStaticCodeCheckValidity(code, [], r) == errSecSuccess {
            return .macAppStore
        }
        guard let leaf = authority(info) else { return .adHoc }
        return .otherAuthority(leaf)
    }

    /// The leaf certificate's subject, tidied. "Developer ID Application: Brave
    /// Software, Inc. (KL8N8XSYF4)" reads better as the company name alone; the
    /// team id is dropped because it identifies the same party twice.
    private static func authority(_ info: [String: Any]) -> String? {
        guard let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certs.first,
              let summary = SecCertificateCopySubjectSummary(leaf) as String? else { return nil }
        var s = summary
        if let colon = s.range(of: "Developer ID Application: ") {
            s = String(s[colon.upperBound...])
        }
        if let paren = s.range(of: " (", options: .backwards), s.hasSuffix(")") {
            s = String(s[..<paren.lowerBound])
        }
        return s.isEmpty ? nil : s
    }
}

/// The launchd job that owns a program, when one can be found on disk.
public struct LaunchdJob: Equatable, Sendable {
    public let label: String
    /// Agents run per-login-session as the user; daemons run once, system-wide,
    /// usually as root.
    public let isAgent: Bool
    /// `KeepAlive` set to a plain true — launchd restarts it unconditionally.
    public let alwaysRestarts: Bool
    /// `KeepAlive` present as a dictionary of conditions ("restart if it crashed",
    /// "restart while this path exists"). Reported separately from `alwaysRestarts`
    /// because "it depends" is the honest answer and "no" would be wrong.
    public let conditionallyRestarts: Bool
    /// Mach service names the job publishes. Apple's own strings, and frequently
    /// the only readable thing about an opaque daemon: `/usr/libexec/dasd`
    /// publishes `com.apple.duetactivityscheduler`.
    public let machServices: [String]
    public let plistPath: String
}

/// Index of every launchd job in the standard folders, keyed by program path.
///
/// WHY AN INDEX AND NOT A LOOKUP: launchd job files are named after the job's
/// label, not after the program it runs, and the two disagree often
/// (`/usr/libexec/keybagd` is `com.apple.mobile.keybagd`, `/usr/libexec/tzd` is
/// `com.apple.timezoneupdates.tzd`). There is no way to find a program's job
/// except to read them all.
///
/// MEASURED on this machine: 928 job files across the five standard folders, 927
/// of which parse, 855 distinct programs, ~150 ms to read and parse the lot. That
/// is far too long to spend on the main thread when a row is clicked, so the
/// first request kicks off a background build and returns nil; the inspector
/// re-renders every two seconds and picks it up on the next tick. Same shape as
/// `SensorCache` and for the same reason.
///
/// ABSENCE IS NOT EVIDENCE OF ABSENCE, and callers must treat it that way. Most
/// modern Apple services are launched through XPC service definitions embedded in
/// frameworks and app bundles, with no file in these folders at all — `nil` here
/// means "no job file found", never "not managed by launchd".
final class LaunchdIndex: @unchecked Sendable {

    static let shared = LaunchdIndex()

    private static let folders: [(path: String, isAgent: Bool)] = [
        ("/System/Library/LaunchDaemons", false),
        ("/System/Library/LaunchAgents", true),
        ("/Library/LaunchDaemons", false),
        ("/Library/LaunchAgents", true),
        (NSHomeDirectory() + "/Library/LaunchAgents", true),
    ]

    private let lock = NSLock()
    private var jobs: [String: LaunchdJob]?
    private var building = false

    /// nil while the index is still being built, or when no job runs this program.
    func job(forProgram path: String) -> LaunchdJob? {
        guard !path.isEmpty else { return nil }
        lock.lock()
        if let jobs { lock.unlock(); return jobs[path] }
        let start = !building
        building = true
        lock.unlock()

        if start {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self else { return }
                let built = Self.build()
                self.lock.lock(); self.jobs = built; self.lock.unlock()
            }
        }
        return nil
    }

    private static func build() -> [String: LaunchdJob] {
        var out: [String: LaunchdJob] = [:]
        let fm = FileManager.default
        for folder in folders {
            guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names where name.hasSuffix(".plist") {
                let file = "\(folder.path)/\(name)"
                guard let data = fm.contents(atPath: file),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                      let d = plist as? [String: Any],
                      let entry = parse(d, isAgent: folder.isAgent, plistPath: file) else { continue }
                out[entry.program] = entry.job
            }
        }
        return out
    }

    /// One job file, already decoded. Pure, so the shape of a job — which
    /// `KeepAlive` spellings mean "always" and which mean "it depends" — can be
    /// tested without any particular Mac having such a job installed.
    ///
    /// A job with no `Program`/`ProgramArguments` is skipped rather than indexed
    /// under an empty key: those are jobs launchd runs some other way, and
    /// mapping them to "" would make every process with no executable path match
    /// the last one read.
    static func parse(_ d: [String: Any],
                      isAgent: Bool,
                      plistPath: String) -> (program: String, job: LaunchdJob)? {
        guard let label = d["Label"] as? String else { return nil }
        let program = (d["Program"] as? String) ?? (d["ProgramArguments"] as? [String])?.first
        guard let program, !program.isEmpty else { return nil }

        // `KeepAlive` is either a bool or a dictionary of conditions
        // ("SuccessfulExit: false" = restart on crash, "PathState" = restart while
        // a file exists). The two cases get different sentences because "it will
        // come back" and "it will come back if it crashes" are different answers.
        let keepAlive = d["KeepAlive"]
        return (program, LaunchdJob(
            label: label,
            isAgent: isAgent,
            alwaysRestarts: (keepAlive as? Bool) == true,
            conditionallyRestarts: keepAlive is [String: Any],
            machServices: ((d["MachServices"] as? [String: Any])?.keys).map { Array($0).sorted() } ?? [],
            plistPath: plistPath))
    }
}

/// Whether quitting this process is a reasonable thing to do — DERIVED, from
/// facts, never asserted.
///
/// Every verdict below is a consequence of something read from the system: our
/// own pid, the uid `kill(2)` will refuse, a launchd job on disk, the bundle
/// shape that says this is a helper of something else. Nothing here encodes an
/// opinion about a specific process, because an opinion about a specific process
/// is exactly the thing that would be silently wrong.
public struct QuitSafety: Equatable, Sendable {

    public enum Verdict: Equatable, Sendable {
        /// Anode itself.
        case isSelf
        /// Another user's — `kill(2)` returns EPERM and no button is offered.
        case notPermitted
        /// A helper of something bigger; quitting it alone breaks the bigger thing.
        case partOfSomethingElse
        /// launchd owns it and will bring it back.
        case respawns
        /// A user-facing app, which may be holding unsaved work.
        case mayHaveUnsavedWork
        /// Nothing found that makes it special.
        case ordinary
    }

    public let verdict: Verdict
    /// One word for a glanceable answer.
    public let answer: String
    /// The reason, which is the part that is actually worth reading.
    public let detail: String

    /// Pure, and takes every input explicitly, so a root pid, a launchd job and
    /// our own pid can all be tested without any of them existing.
    ///
    /// ORDER IS THE DESIGN. Signalability comes first because it decides whether
    /// there is a button at all — `ProcessSignalability.canSignal` is the same
    /// call `ProcessActions.plan` makes, so the sentence and the button cannot
    /// disagree. Unsaved work comes next, because losing a document is the worst
    /// outcome available here and it outranks the mere annoyance of a service
    /// coming back. `respawns` comes last of the specific cases: it is a reason
    /// quitting will not ACHIEVE anything, not a reason it will hurt.
    public static func of(pid: pid_t,
                          uid: uid_t,
                          owner: String?,
                          form: ProcessForm,
                          containerName: String?,
                          job: LaunchdJob?,
                          parentIsLaunchd: Bool,
                          currentUID: uid_t = getuid(),
                          selfPID: pid_t = getpid()) -> QuitSafety {

        if pid == selfPID {
            return QuitSafety(verdict: .isSelf, answer: "No",
                              detail: "This is Anode. It does not offer to quit itself — "
                                    + "it could not report what happened.")
        }
        // Before the uid test, because pid 0 is `kernel_task` and its uid says
        // nothing useful: `kill(2)` would read the 0 as "our whole process group"
        // rather than as a target, so the reason it cannot be quit is not
        // ownership and must not be reported as ownership.
        if form == .kernel || pid <= 0 {
            return QuitSafety(verdict: .notPermitted, answer: "Not possible",
                              detail: "This is the kernel's own task. It has no executable file "
                                    + "and cannot be signalled.")
        }
        if !ProcessSignalability.canSignal(pid: pid, uid: uid,
                                           currentUID: currentUID, selfPID: selfPID) {
            let who = owner ?? "uid \(uid)"
            return QuitSafety(verdict: .notPermitted, answer: "Not possible",
                              detail: "Owned by \(who). An unprivileged process cannot signal it, "
                                    + "so Anode does not offer a button that could only fail.")
        }
        if let container = containerName {
            return QuitSafety(verdict: .partOfSomethingElse, answer: "Not on its own",
                              detail: "A helper process of \(container). Quitting it alone can "
                                    + "leave \(container) wedged or missing a feature — quit "
                                    + "\(container) instead.")
        }
        if form == .application {
            return QuitSafety(verdict: .mayHaveUnsavedWork, answer: "Yes, with care",
                              detail: "A user-facing app, so it may be holding unsaved work. Quit "
                                    + "asks it to save first; Force Quit does not.")
        }
        if let job {
            let restart = job.alwaysRestarts
                ? "launchd will start it again immediately (its job sets KeepAlive)"
                : (job.conditionallyRestarts
                    ? "launchd will start it again when its job's conditions are met"
                    : "launchd will start it again the next time something asks for it")
            return QuitSafety(verdict: .respawns, answer: "Yes, but it will come back",
                              detail: "Managed by the launchd job \(job.label), so \(restart).")
        }
        if parentIsLaunchd {
            return QuitSafety(verdict: .respawns, answer: "Yes, but it may come back",
                              detail: "Started by launchd. No job file for it was found in the "
                                    + "standard folders, so whether it restarts depends on a "
                                    + "definition this app cannot read.")
        }
        return QuitSafety(verdict: .ordinary, answer: "Yes",
                          detail: "Nothing about this process suggests quitting it is unusual.")
    }
}

/// Everything locally knowable about one process, in one value.
///
/// What this CANNOT determine, and deliberately does not fake:
///   • What an undocumented daemon actually does. 64 of the executables running
///     on this machine are bare binaries in system locations with no man page, no
///     bundle and no descriptive field anywhere in their launchd job. `purpose`
///     is nil for them and the UI shows "—".
///   • Whether a process is misbehaving. Nothing here reads its behaviour.
///   • Anything about a cross-uid process beyond its uid and path —
///     `ProcessInspector.details` is same-uid only for the counters, the same
///     ~63% boundary as the energy figures.
///   • Whether an app has unsaved work RIGHT NOW. `mayHaveUnsavedWork` says it
///     could, from the fact that it is a user-facing app; no public API reports
///     the document state of another process.
public struct ProcessExplanation: Sendable {
    public let pid: pid_t
    public let name: String
    public let executablePath: String

    public let form: ProcessForm
    public let domain: InstallDomain
    public let origin: CodeOrigin
    public let bundle: BundleFacts
    public let bundlePath: String?
    /// The app or framework this is a part of, when it is a part of one.
    public let containerName: String?
    public let job: LaunchdJob?

    /// What it does, in Apple's words or ours. nil when nothing on this machine
    /// says — which is honest, and common.
    public let purpose: String?
    /// Where `purpose` came from, so the claim can be traced.
    public let purposeSource: PurposeSource?

    public let safety: QuitSafety

    public enum PurposeSource: Equatable, Sendable {
        /// The man page macOS shipped for this binary.
        case manPage
        /// A sentence written in `ProcessCatalog`, corroborated by a string on
        /// this machine.
        case catalog
        /// The bundle's own `CFBundleDisplayName`.
        case bundleName
    }

    public var purposeAttribution: String? {
        switch purposeSource {
        case .manPage:    return "from the man page macOS ships for it"
        case .catalog:    return "from where it is installed"
        case .bundleName: return "the name its own bundle declares"
        case nil:         return nil
        }
    }

    /// The one-line "what is this", built ONLY from things that were read.
    ///
    /// Three clauses joined the way the rest of this app joins facts, rather than
    /// one comma-spliced sentence: each part is a separate finding and a reader
    /// scanning for "is this Apple's" should not have to parse a sentence to find
    /// it. A clause whose fact is missing is dropped rather than filled in.
    ///
    ///   "An app extension · signed by Apple as part of macOS · in the sealed
    ///    system volume, which only macOS itself writes to"
    public var headline: String {
        var parts = [form.text]
        if origin != .unknown { parts.append(origin.text) }
        if domain != .unknown { parts.append(domain.text) }
        return parts.joined(separator: " · ")
    }
}

/// Builds a `ProcessExplanation`, and caches the expensive half.
public enum ProcessExplainer {

    /// Facts that depend only on the executable path, not on the pid. Signature
    /// verification is up to 69 ms and the man page is a file read; a process
    /// list has many pids per path (fifteen `Code Helper` rows share one binary)
    /// and the inspector re-renders every two seconds, so this is cached.
    private struct PathFacts {
        let shape: BundleShape
        let domain: InstallDomain
        let origin: CodeOrigin
        let bundle: BundleFacts
        let purpose: String?
        let purposeSource: ProcessExplanation.PurposeSource?
    }

    private static var cache: [String: PathFacts] = [:]
    private static let cacheLock = NSLock()

    public static func explain(_ d: ProcessDetails) -> ProcessExplanation {
        let facts = pathFacts(d.executablePath)
        let job = LaunchdIndex.shared.job(forProgram: d.executablePath)
        // pid 0 has no executable file to shape, and is the one process whose
        // form cannot be read off a path.
        let form: ProcessForm = d.pid == 0 ? .kernel : facts.shape.form

        return ProcessExplanation(
            pid: d.pid,
            name: d.name,
            executablePath: d.executablePath,
            form: form,
            domain: facts.domain,
            origin: facts.origin,
            bundle: facts.bundle,
            bundlePath: facts.shape.bundlePath,
            containerName: facts.shape.containerName,
            job: job,
            purpose: facts.purpose,
            purposeSource: facts.purposeSource,
            safety: QuitSafety.of(pid: d.pid,
                                  uid: d.uid,
                                  owner: d.userName,
                                  form: form,
                                  containerName: facts.shape.containerName,
                                  job: job,
                                  // launchd is pid 1 by POSIX convention and by
                                  // measurement here: 850 of ~940 processes on
                                  // this machine report it as their parent.
                                  parentIsLaunchd: d.parentPID == 1))
    }

    private static func pathFacts(_ path: String) -> PathFacts {
        cacheLock.lock()
        if let hit = cache[path] { cacheLock.unlock(); return hit }
        cacheLock.unlock()

        let shape = BundleShape.of(path: path)
        let bundle = shape.bundlePath.map(BundleFacts.read) ?? .empty
        let (purpose, source) = describe(path: path, bundle: bundle)
        let facts = PathFacts(shape: shape,
                              domain: InstallDomain.of(path: path),
                              origin: CodeSignature.origin(ofExecutableAt: path),
                              bundle: bundle,
                              purpose: purpose,
                              purposeSource: source)

        cacheLock.lock(); cache[path] = facts; cacheLock.unlock()
        return facts
    }

    /// Source precedence, strongest first — see `ProcessCatalog` for what makes
    /// one source stronger than another.
    ///
    /// The bundle's display name is last, and it is fenced twice.
    ///
    /// It must be THIS binary's bundle: a bundle's name describes the bundle's own
    /// main executable, never every file underneath it. `xctest` shipping inside
    /// `Xcode.app` is not "Xcode", and reporting it as such is exactly the kind of
    /// confident wrong answer this whole file is arranged to avoid — it was the
    /// first thing the explainer got wrong when it was run against a real pid.
    ///
    /// And it must say something the process name does not:
    /// "TGOnDeviceInferenceProviderService is called
    /// TGOnDeviceInferenceProviderService" is not a description. What survives
    /// both fences is the useful case — a process called `Electron` whose bundle
    /// says it is Visual Studio Code.
    static func describe(path: String,
                         bundle: BundleFacts) -> (String?, ProcessExplanation.PurposeSource?) {
        if let man = ManPage.description(forExecutableAt: path) { return (man, .manPage) }
        if let curated = ProcessCatalog.curated(forExecutablePath: path) { return (curated, .catalog) }
        let exe = (path as NSString).lastPathComponent
        if let display = bundle.displayName, bundle.executableName == exe,
           display != exe, !display.isEmpty {
            return (display, .bundleName)
        }
        return (nil, nil)
    }
}

// ─────────────────────────────────────────────────────────────────────────────

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

    /// `kill(2)` reads non-positive pids as BROADCASTS, not as targets: 0 means
    /// every process in our process group, -1 means every process this user is
    /// allowed to signal, and any other negative number means a whole process
    /// group. None of those is ever what a click on a row meant.
    ///
    /// pid 0 is not hypothetical here — it is `kernel_task`, which appears in
    /// process listings like anything else. A row that reads "kernel_task" and a
    /// Force Quit button that SIGKILLs our own process group is the worst bug
    /// this file could have, so the guard sits at the bottom, in the only
    /// function that calls `kill`, as well as at the two entry points.
    public static func isSignalable(_ pid: pid_t) -> Bool { pid > 0 && !isSelf(pid) }

    public static func quit(pid: pid_t) -> Result {
        guard isSignalable(pid) else { return .notPermitted }

        // A GUI app gets the Apple Event, which lets it save and prompt. SIGTERM
        // would skip all of that.
        if let app = NSRunningApplicationShim.application(pid: pid) {
            return app.terminate() ? .requested : .failed(0)
        }
        return signal(pid, SIGTERM)
    }

    public static func forceQuit(pid: pid_t) -> Result {
        guard isSignalable(pid) else { return .notPermitted }
        if let app = NSRunningApplicationShim.application(pid: pid) {
            return app.forceTerminate() ? .killed : .failed(0)
        }
        return signal(pid, SIGKILL) == .requested ? .killed : signal(pid, SIGKILL)
    }

    private static func signal(_ pid: pid_t, _ sig: Int32) -> Result {
        guard isSignalable(pid) else { return .notPermitted }
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
