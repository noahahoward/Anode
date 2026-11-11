import AppKit
import PowerKit

// ── Did the last run end properly, and what was it doing? ───────────────────
//
// macOS writes a crash report when a program crashes; when it is killed instead (out of memory, or by the
// system for a permission change) it writes none, and nothing on the Mac says what happened. A MacBook Neo's
// owner reported Anode "crashing" after switching windows with no report anywhere, so the app now keeps its
// own account in `run.log` (Anode's support folder): a line when the switcher opens and when a window is
// chosen, with the memory the app held, and a line at launch if the run before did not quit through the
// normal route. The lines before that one are what it was doing.
//
// Two small files, no timers, and a line only at the steps named below. Nothing the user typed or any window
// title is written, only the app's name and sizes.

enum RunTrace {

    private static var markerURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Anode/running")
    }

    /// The pid of a run that did not quit normally, from the marker it left, or nil when the last run ended
    /// properly (no marker), the marker is unreadable, it is this very process, or that process is still alive
    /// (another copy running now, not a run that ended). Pure, for tests.
    static func runThatEndedBadly(marker: String?, current: pid_t, isAlive: (pid_t) -> Bool) -> pid_t? {
        guard let marker, let previous = pid_t(marker.trimmingCharacters(in: .whitespacesAndNewlines)),
              previous != current, !isAlive(previous) else { return nil }
        return previous
    }

    /// First thing at launch: note a run that never reached `cleanExit`, then mark this one as running.
    static func launch(pid: pid_t = getpid()) {
        guard let url = markerURL else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let marker = try? String(contentsOf: url, encoding: .utf8)
        if let previous = runThatEndedBadly(marker: marker, current: pid, isAlive: { kill($0, 0) == 0 }) {
            FeatureLog.append("run.log", "launch: the run before (pid \(previous)) did not quit normally — "
                              + "it crashed or was killed; the lines above are what it was doing")
        }
        try? "\(pid)".write(to: url, atomically: true, encoding: .utf8)
        FeatureLog.append("run.log", "launch pid \(pid), \(ProcessInfo.processInfo.operatingSystemVersionString), \(footprint())")
    }

    /// The normal route out (`applicationWillTerminate`).
    static func cleanExit() {
        FeatureLog.append("run.log", "quit normally, \(footprint())")
        if let url = markerURL { try? FileManager.default.removeItem(at: url) }
    }

    /// One step of something that could be the last one.
    static func step(_ text: String) {
        FeatureLog.append("run.log", "\(text), \(footprint())")
    }

    /// The memory this app holds, as a short phrase.
    static func footprint() -> String {
        guard let s = SelfUsage.read(gpu: nil) else { return "memory ?" }
        return "memory \(s.footprint / 1_048_576) MB"
    }
}
