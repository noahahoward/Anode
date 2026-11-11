import AppKit
import IOKit
import PowerKit

// ── Can anyone see a screen? ────────────────────────────────────────────────
//
// Everything this app does for the eye (the 2 s tick, the process table, the graph, a video wallpaper) is gated on a
// window being on screen. A shut lid with nothing else plugged in leaves one case that gate cannot see:
//
//   Always Stay Awake keeps a MacBook running with the lid closed and turns the panel's brightness down to 0. The
//   display is NOT asleep (that is the point of the mode, the system is kept awake), so no window is occluded and
//   nothing posts a notification. The app kept drawing, at the fast rate, for a panel nobody could see.
//
// MEASURED, from the app's own history (7 days, per-minute energy of this app while on battery): a 102 minute
// lid-closed session ran this app at 400-600 mW, steady, against about 2 mW at any other time it was closed to the
// menu bar. That was 1.0 Wh, 23 % of the whole Mac's energy over those minutes and more than every other app together,
// spent in a bag. It began at the minute the log says "lid closed: brightness → 0" and ended at the minute the lid
// opened, and the compaction spikes in it came every 8.5 minutes, which is 256 records at the 2 s window cadence: the
// app believed someone was reading.
//
// The answer is the lid, plus the one thing that makes a shut lid still watched: another display. A MacBook in
// clamshell mode with an external monitor has its lid shut and its owner looking at the monitor.
//
// Unknown is "watched". No lid (a desktop), or a lid state that cannot be read, must never make the app go quiet.

enum ScreenAttention {

    /// True unless the lid is shut and no other display is on. Pure, so every combination is a test.
    static func someoneCanSee(lidClosed: Bool?, externalDisplayActive: Bool) -> Bool {
        guard lidClosed == true else { return true }
        return externalDisplayActive
    }

    /// Any active display that is not the built-in panel: a monitor, a TV, an AirPlay or Sidecar screen.
    static func anyExternalDisplayActive() -> Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return true }
        return ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }
}

/// The answer, kept current. Main thread only, like everything it feeds.
///
/// Event-driven, as the rest of this app's gating is: the power-management root domain tells it about a lid change, a
/// display being plugged in or out tells it about the other half, and the sampler asks once per tick as the net under
/// both, so a missed notification can strand the answer for one tick and no longer.
final class ScreenWatch {

    static let shared = ScreenWatch()

    private let lid: LidStateReader
    private let externalDisplayActive: () -> Bool
    private let now: () -> Date
    private let log: (String) -> Void
    private let cpuSeconds: () -> Double

    /// Whether someone can see a screen. Starts true: until it has looked, assume they can.
    private(set) var isWatched = true
    /// Told, on the main thread, each time `isWatched` changes (the value is the new one).
    var onChange: ((Bool) -> Void)?

    private var unwatchedSince: Date?
    private var cpuAtUnwatched = 0.0
    private var started = false
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(lid: LidStateReader = IOKitLidState(),
         externalDisplayActive: @escaping () -> Bool = ScreenAttention.anyExternalDisplayActive,
         now: @escaping () -> Date = Date.init,
         cpuSeconds: @escaping () -> Double = ScreenWatch.processCPUSeconds,
         log: @escaping (String) -> Void = { FeatureLog.append("run.log", $0) }) {
        self.lid = lid
        self.externalDisplayActive = externalDisplayActive
        self.now = now
        self.cpuSeconds = cpuSeconds
        self.log = log
    }

    deinit { stop() }

    /// Re-read the lid and the displays. Returns the answer. Cheap when the lid is open, which is nearly always: one
    /// registry property, and the display list is only asked for when the lid is shut.
    @discardableResult
    func update(notify: Bool = true) -> Bool {
        let closed = lid.isClosed()
        let watched = ScreenAttention.someoneCanSee(
            lidClosed: closed, externalDisplayActive: closed == true ? externalDisplayActive() : true)
        guard watched != isWatched else { return watched }
        isWatched = watched
        record(watched)
        if notify { onChange?(watched) }
        return watched
    }

    /// What the log says about it, and the evidence for the next time someone asks "why is it using battery": how
    /// long nobody was looking and what share of a core this process used meanwhile.
    private func record(_ watched: Bool) {
        let at = now(), cpu = cpuSeconds()
        if !watched {
            unwatchedSince = at
            cpuAtUnwatched = cpu
            log("screen: lid shut, no other display — nobody can see it, so sampling and drawing slow right down")
        } else if let since = unwatchedSince {
            let seconds = max(1, at.timeIntervalSince(since))
            log(String(format: "screen: watched again after %d s; this app used %.2f %% of a core meanwhile",
                       Int(seconds), (cpu - cpuAtUnwatched) / seconds * 100))
            unwatchedSince = nil
        }
    }

    // ── Events ──────────────────────────────────────────────────────────────

    func start() {
        guard !started else { return }
        started = true
        // A lid change is a message to the power-management root domain. Whatever the message, the answer is the
        // same one registry read, so the callback asks again instead of decoding a message number.
        if let port = IONotificationPortCreate(kIOMainPortDefault) {
            notifyPort = port
            CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
            let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
            if root != 0 {
                let status = IOServiceAddInterestNotification(port, root, kIOGeneralInterest, { refcon, _, _, _ in
                    guard let refcon else { return }
                    Unmanaged<ScreenWatch>.fromOpaque(refcon).takeUnretainedValue().update()
                }, Unmanaged.passUnretained(self).toOpaque(), &notifier)
                IOObjectRelease(root)
                if status != KERN_SUCCESS {
                    log("screen: no lid notifications (status \(status)); the sampler checks the lid once per tick instead")
                }
            }
        }
        // A monitor plugged in or out changes the answer without any lid event.
        let nc = NotificationCenter.default
        observers.append((nc, nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                             object: nil, queue: .main) { [weak self] _ in self?.update() }))
        let ws = NSWorkspace.shared.notificationCenter
        observers.append((ws, ws.addObserver(forName: NSWorkspace.didWakeNotification,
                                             object: nil, queue: .main) { [weak self] _ in self?.update() }))
        update()
    }

    func stop() {
        guard started else { return }
        started = false
        if notifier != 0 { IOObjectRelease(notifier); notifier = 0 }
        if let port = notifyPort {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
        for (center, o) in observers { center.removeObserver(o) }
        observers.removeAll()
    }

    /// User plus system CPU seconds this process has used.
    static func processCPUSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return s(u.ru_utime) + s(u.ru_stime)
    }
}
