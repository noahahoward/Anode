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

    /// The normal route out (`applicationWillTerminate`). Says who asked, because "Anode quit" is not one
    /// story: a ⌘Q, a click on a Quit item, another program's Apple event (the updater, System Settings'
    /// "Quit & Reopen"), or this app's own code all arrive here the same way and the system log cannot tell them
    /// apart (measured on a MacBook Neo: `terminate:` and a clean exit, no crash report, no sender).
    static func cleanExit() {
        FeatureLog.append("run.log", "quit normally, \(footprint()); asked by: \(causeOfADeferredQuit ?? quitCause())")
        for line in callers() { FeatureLog.append("run.log", "  via: \(line)") }
        if let url = markerURL { try? FileManager.default.removeItem(at: url) }
    }

    /// Who asked for a quit that could not happen inside its own event, because a dialog had to be dismissed first
    /// (`QuitRequest`): by the time `terminate` runs, the Apple event is no longer the current one.
    static var causeOfADeferredQuit: String?

    /// Four letters of an Apple event class or id, as they are written ('aevt', 'quit').
    static func fourCharacterCode(_ code: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .macOSRoman) ?? "????"
    }

    /// What was being handled when the app was told to quit: a key (which), a click, or an Apple event (from
    /// which program). Read inside `applicationWillTerminate`, which runs inside `terminate:`, so it is still current.
    static func quitCause() -> String {
        var parts: [String] = []
        // `currentEvent` is the last event the app was given, which can be minutes old (a mouse move, in the
        // first test of this): only a key or a click from the last moment can have been the cause.
        if let e = NSApp?.currentEvent, ProcessInfo.processInfo.systemUptime - e.timestamp < 0.5 {
            switch e.type {
            case .keyDown: parts.append("key \"\(e.charactersIgnoringModifiers ?? "?")\" code \(e.keyCode) flags \(e.modifierFlags.rawValue >> 16)")
            case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp: parts.append("a click")
            default: break
            }
        }
        if let ae = NSAppleEventManager.shared().currentAppleEvent {
            let senderPID = ae.attributeDescriptor(forKeyword: 0x73706964 /* 'spid' */)?.int32Value ?? 0
            let sender = senderPID > 0 ? (NSRunningApplication(processIdentifier: senderPID)?.localizedName ?? "pid \(senderPID)") : "unknown"
            parts.append("Apple event \(fourCharacterCode(ae.eventClass))/\(fourCharacterCode(ae.eventID)) from \(sender)")
        }
        return parts.isEmpty ? "no event in progress (this app's own code, or the system)" : parts.joined(separator: "; ")
    }

    /// The frames that led to `terminate:`, innermost first, as short names, in lines that fit the log's limit.
    /// A menu or key gives AppKit's menu frames, an Apple event its handler, this app's own code one of its
    /// own closures: which of them is the answer to "who asked".
    static func callers() -> [String] {
        let names = Thread.callStackSymbols.compactMap { line -> String? in
            // "12  AppKit  0x000... -[NSMenuItem _corePerformAction] + 123": keep what follows the address.
            guard let r = line.range(of: " 0x") else { return nil }
            let rest = line[r.upperBound...].drop { $0 != " " }.dropFirst()
            guard let name = rest.split(separator: "+").first.map({ String($0).trimmingCharacters(in: .whitespaces) }),
                  !name.isEmpty else { return nil }
            return name.count > 44 ? String(name.prefix(44)) + "…" : name
        }
        // From the call to terminate: outward; without one in the list, the outermost frames.
        let from = names.firstIndex { $0.contains("terminate:") }.map { $0 + 1 } ?? max(0, names.count - 10)
        let wanted = Array(names[min(from, names.count)...].prefix(12))
        var lines: [String] = [], current = ""
        for n in wanted {
            if current.count + n.count > 170 { lines.append(current); current = "" }
            current += current.isEmpty ? n : " < " + n
        }
        if !current.isEmpty { lines.append(current) }
        return lines
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
