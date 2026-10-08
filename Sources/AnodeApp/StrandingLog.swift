import AppKit

/// Writes down WHEN the main window becomes stranded, so the next occurrence
/// can be matched against what the machine was doing at that moment.
///
/// `WindowPresence` records what a stranded window is and how to get it back.
/// What it could not say is what strands it: the one process it was measured in
/// had been up a day and a half, and by then the moment was long gone. The
/// Space's id had changed, so macOS rebuilt it — on lid close, display sleep, a
/// resolution change, something else — and that is a guess until an onset has a
/// timestamp to lay beside `pmset -g log`.
///
/// Checked on the tick, which already runs on the main thread, so the onset is
/// caught within one sample interval. Logged on the TRANSITION only: a window
/// stranded for a day is one line, not ten thousand.
struct StrandingLog {

    enum Event: Equatable {
        case began(at: Date)
        case ended(at: Date, after: TimeInterval)
    }

    private var since: Date?

    /// Feed the current reading; returns an event only when the state changes.
    mutating func observe(stranded: Bool, at now: Date = Date()) -> Event? {
        switch (since, stranded) {
        case (nil, true):
            since = now
            return .began(at: now)
        case (let start?, false):
            since = nil
            return .ended(at: now, after: now.timeIntervalSince(start))
        default:
            return nil
        }
    }

    static func line(for event: Event, context: String = "") -> String {
        let stamp = ISO8601DateFormatter.string(
            from: { if case .began(let d) = event { return d }
                    if case .ended(let d, _) = event { return d }
                    return Date() }(),
            timeZone: .current, formatOptions: [.withInternetDateTime])
        switch event {
        case .began:
            return "\(stamp) STRANDED \(context)"
        case .ended(_, let after):
            return "\(stamp) recovered after \(Int(after.rounded())) s \(context)"
        }
    }

    /// Beside the history database, so it is found with everything else this app
    /// keeps and removed by the same uninstall.
    static var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Anode/window-stranding.log")
    }

    /// Appends one line. Off the main thread: this is a file write on a path
    /// that is taken only when something has already gone wrong, and it must not
    /// be the thing that makes the tick late.
    ///
    /// A SERIAL queue, not the global one: two appends racing on a concurrent
    /// queue can both find no file and both create it, and the second create
    /// replaces the first line. An onset and its recovery a tick apart is
    /// exactly two appends in quick succession.
    private static let writer = DispatchQueue(label: "Anode.StrandingLog", qos: .utility)

    static func append(_ line: String, to url: URL? = fileURL) {
        guard let url else { return }
        writer.async {
            let data = Data((line + "\n").utf8)
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
            } else {
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: url)
            }
        }
    }
}
