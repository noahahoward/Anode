import AppKit
import Foundation

/// Resolves a process to the user-visible application that owns it.
///
/// This is the fix for the single most misleading thing Activity Monitor does:
/// showing nine `Brave Browser Helper` rows and fifteen `Code Helper (Renderer)`
/// rows instead of one Brave row and one VS Code row. A browser fragmented across
/// nine processes looks cheap in every individual row while being expensive in
/// aggregate, which is exactly backwards from what a user needs to decide what to quit.
///
/// Strategy: walk the executable path and take the OUTERMOST `.app` ancestor.
///   /Applications/Brave Browser.app/Contents/Frameworks/…/Brave Browser Helper.app/…
///     -> /Applications/Brave Browser.app        -> "Brave Browser"
///   /Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/…
///     -> /Applications/Visual Studio Code.app   -> "Visual Studio Code"
///   /usr/libexec/contactsd
///     -> no bundle                              -> "contactsd" (daemon, left alone)
///
/// No private API, no entitlement. Handles Electron/Chromium multi-process apps and
/// app-owned XPC services, which together are the overwhelming majority of the problem.
public struct AppIdentity: Hashable {
    public let name: String
    public let bundlePath: String?
    public let bundleID: String?
    /// True when this resolved to a real `.app`, false for daemons and helpers
    /// that live outside any bundle.
    public let isApp: Bool

    public static let unknown = AppIdentity(name: "—", bundlePath: nil, bundleID: nil, isApp: false)
}

public enum AppResolver {
    private static var cacheByPath: [String: AppIdentity] = [:]
    private static var cacheByPID: [ProcessKey: AppIdentity] = [:]
    private static let lock = NSLock()

    public static func identity(for pid: pid_t, key: ProcessKey) -> AppIdentity {
        lock.lock()
        if let hit = cacheByPID[key] { lock.unlock(); return hit }
        lock.unlock()

        let path = executablePath(pid)
        let id = identity(forExecutablePath: path, fallbackPID: pid)

        lock.lock(); cacheByPID[key] = id; lock.unlock()
        return id
    }

    public static func executablePath(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4 * 1024)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return "" }
        return String(cString: buf)
    }

    public static func identity(forExecutablePath path: String, fallbackPID: pid_t = 0) -> AppIdentity {
        guard !path.isEmpty else {
            return AppIdentity(name: "pid \(fallbackPID)", bundlePath: nil, bundleID: nil, isApp: false)
        }

        lock.lock()
        if let hit = cacheByPath[path] { lock.unlock(); return hit }
        lock.unlock()

        let id = resolve(path)

        lock.lock(); cacheByPath[path] = id; lock.unlock()
        return id
    }

    private static func resolve(_ path: String) -> AppIdentity {
        let parts = path.components(separatedBy: "/")

        // OUTERMOST .app wins — the first `.app` component walking down from root.
        // Taking the innermost would give "Brave Browser Helper", which is the bug.
        if let idx = parts.firstIndex(where: { $0.hasSuffix(".app") }) {
            let bundlePath = parts[0...idx].joined(separator: "/")
            let fallback = String(parts[idx].dropLast(4))

            // Name priority is deliberate. The Info.plist is NOT authoritative for the
            // user-visible name and following it produces wrong labels:
            //   Visual Studio Code.app -> CFBundleName/DisplayName are both "Code"
            //   Brave Browser.app      -> CFBundleName is "Brave"
            // Finder shows the BUNDLE FILENAME, so that is what a person recognises.
            // FileManager.displayName honours localized bundle names too, and falls
            // back to the filename, so it is the closest match to what the user sees.
            let display = FileManager.default.displayName(atPath: bundlePath)
            let name = display.hasSuffix(".app") ? String(display.dropLast(4)) : display

            let bundle = Bundle(path: bundlePath)
            return AppIdentity(name: name.isEmpty ? fallback : name,
                               bundlePath: bundlePath,
                               bundleID: bundle?.bundleIdentifier,
                               isApp: true)
        }

        // No bundle: a daemon or CLI. Its own name is already the right label.
        return AppIdentity(name: (path as NSString).lastPathComponent,
                           bundlePath: nil, bundleID: nil, isApp: false)
    }
}

/// Per-application drain, summed across every process the app owns.
public struct AppDrain {
    public let identity: AppIdentity
    public let joules: Double
    public let watts: Double
    public let percentPerHour: Double
    public let processCount: Int
    public let pids: [pid_t]
    /// Summed across the app's processes — the whole point of the rollup.
    public let cpuPercent: Double
    public let memoryBytes: UInt64
    public let diskReadPerSec: Double
    public let diskWrittenPerSec: Double
    public var diskBytesPerSec: Double { diskReadPerSec + diskWrittenPerSec }

    public var name: String { identity.name }
    public var isApp: Bool { identity.isApp }
}

public extension DrainCalculator {
    /// Collapse per-process drain into per-application drain.
    static func group(_ drains: [ProcessDrain], scale: BatteryScale) -> [AppDrain] {
        var byApp: [AppIdentity: (j: Double, w: Double, cpu: Double,
                                  mem: UInt64, read: Double, written: Double, pids: [pid_t])] = [:]

        for d in drains {
            // Path already captured during the sweep — no syscall here.
            let id = AppResolver.identity(forExecutablePath: d.path, fallbackPID: d.pid)
            var e = byApp[id] ?? (0, 0, 0, 0, 0, 0, [])
            e.j += d.joules
            e.w += d.watts
            e.cpu += d.cpuPercent
            e.mem &+= d.memoryBytes
            e.read += d.diskReadPerSec
            e.written += d.diskWrittenPerSec
            e.pids.append(d.pid)
            byApp[id] = e
        }

        return byApp.map { id, e in
            AppDrain(identity: id,
                     joules: e.j,
                     watts: e.w,
                     percentPerHour: 3600 * e.w / scale.joulesPerPercent,
                     processCount: e.pids.count,
                     pids: e.pids.sorted(),
                     cpuPercent: e.cpu,
                     memoryBytes: e.mem,
                     diskReadPerSec: e.read,
                     diskWrittenPerSec: e.written)
        }
        .sorted { $0.percentPerHour > $1.percentPerHour }
    }
}
