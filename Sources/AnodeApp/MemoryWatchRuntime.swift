import Foundation
import PowerKit

/// The real parts of Memory Watch, for the app: the process readers, the notification center, the sampling queue and the
/// diagnostic window. Nothing here runs until the setting is on: the controller made here holds only an observer of the
/// setting until then, and a window is built the first time a banner is clicked, not before.
enum MemoryWatchRuntime {

    /// Never candidates: Anode's own executable and the bundle around it. Its worker copies (`--ultra-watchdog`,
    /// `--charge-watchdog`, `--hard-drain-worker` are this same program started again) have the same executable path, so one
    /// entry covers them all; the symlink-resolved spelling too, because `proc_pidpath` may give either.
    static func excludedPaths(bundlePath: String? = Bundle.main.bundlePath,
                              executablePath: String? = Bundle.main.executablePath) -> Set<String> {
        var out: Set<String> = []
        var executables: [String] = []
        if let executablePath { executables.append(executablePath) }
        executables += executables.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        for executable in executables {
            out.insert(executable)
            out.insert(IdentityKey.key(forExecutablePath: executable).key)   // the .app around it
        }
        if let bundlePath {
            out.insert(bundlePath)
            out.insert(URL(fileURLWithPath: bundlePath).resolvingSymlinksInPath().path)
        }
        return out
    }

    /// - Parameters:
    ///   - sampling: the queue that owns the watch (the app's sampling queue).
    ///   - attach: gives the sampling tick the watch it feeds; called on `sampling`.
    ///   - openProcesses: shows the app in Anode's Processes view.
    ///   - bringForward: brings Anode forward (a click on a banner whose finding is gone).
    static func live(settings: Settings = .shared, sampling: DispatchQueue,
                     attach: @escaping (MemoryWatching?) -> Void,
                     openProcesses: @escaping (Finding) -> Void,
                     bringForward: @escaping () -> Void) -> MemoryWatchController {
        let excluded = excludedPaths()
        final class Box { weak var controller: MemoryWatchController? }
        let box = Box()
        let controller = MemoryWatchController(
            settings: settings,
            notifier: UNLeakNotifier(),
            makeWatch: {
                MemoryWatch(ownPID: getpid(),
                            excludedPaths: excluded,
                            pathOf: { ProcessSampler.path(of: $0) },
                            // Read when a process is considered for the table (a discovery pass, never a sample), so a
                            // change made in Beta Features applies at once.
                            isIgnored: { settings.memoryWatchIgnoredApps.contains($0) },
                            footprintOf: { ProcessSampler.footprint(of: $0) },
                            discover: { ProcessSampler.footprints() })
            },
            onSampling: { sampling.async(execute: $0) },
            attach: attach,
            makeWindow: { finding in
                MemoryWatchWindowController(finding: finding,
                                            ignoreApp: { box.controller?.ignore(identityKey: $0) },
                                            showInProcesses: openProcesses)
            },
            bringForward: bringForward)
        box.controller = controller
        MemoryWatchController.current = controller
        return controller
    }
}
