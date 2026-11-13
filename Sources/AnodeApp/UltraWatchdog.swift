import Darwin
import Foundation
import PowerKit

/// The watchdog of Ultra Low Power Mode: a child of Anode that continues every frozen app at once if Anode dies.
///
/// A frozen app stays frozen for good if nobody continues it, and Anode is the one that does. So while the mode is on,
/// Anode starts itself again with `--ultra-watchdog <its pid> <the record's path>`. That process does nothing and
/// costs nothing until Anode's pid exits (it sleeps in the kernel until the event arrives, it does not poll). Then it
/// reads the record and undoes what it can without a window, an app or any setting of Anode's: continuing what the
/// record names and putting the brightness back. Unhiding, the keyboard light and the power mode are left for the next
/// launch, which reads the same record; the refresh rate needs nothing, the system takes it back with the process.
///
/// A normal end is Anode's job, not the watchdog's: `stop()` ends it with SIGTERM and it exits without undoing.

protocol UltraWatchdogging: AnyObject {
    func start()
    func stop()
}

// ── Anode's side ────────────────────────────────────────────────────────────

/// Starts and stops the watchdog from Anode. Called from the main thread, by the controller.
final class LiveUltraWatchdog: UltraWatchdogging {

    private let recordURL: URL
    private let log: (String) -> Void
    private var process: Process?

    init(recordURL: URL, log: @escaping (String) -> Void = { _ in }) {
        self.recordURL = recordURL
        self.log = log
    }

    /// What the program is started with, after its own path. `UltraWatchdog.parse` reads it back.
    static func arguments(parent: pid_t, recordURL: URL) -> [String] {
        [UltraWatchdog.argument, String(parent), recordURL.path]
    }

    /// Does nothing while one is running already.
    func start() {
        if process?.isRunning == true { return }
        guard let executable = Bundle.main.executableURL else {
            log("ultra watchdog: this program has no executable to start again")
            return
        }
        let child = Process()
        child.executableURL = executable
        child.arguments = Self.arguments(parent: getpid(), recordURL: recordURL)
        // Nothing of Anode's to hold on to: a pipe it shares with Anode would outlive Anode's end and keep the other
        // side of it open.
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        do {
            try child.run()
            process = child
        } catch {
            // The record is on disk all the same, so the next launch can still finish the undo.
            log("ultra watchdog: could not start (\(error.localizedDescription))")
        }
    }

    /// Ends it without undoing. Does nothing when none runs.
    func stop() {
        guard let child = process else { return }
        process = nil
        // `terminate()` on a process that has ended is for the system to refuse, not for this to find out.
        if child.isRunning { child.terminate() }
    }
}

// ── The watchdog itself ─────────────────────────────────────────────────────

enum UltraWatchdog {

    static let argument = "--ultra-watchdog"

    struct Request: Equatable {
        var parent: pid_t
        var recordPath: String
    }

    enum Wait: Equatable {
        /// The process ended, or was already gone.
        case exited
        case timedOut
        /// The kernel would not take the request: nothing is known about the process.
        case failed
    }

    /// The very first thing the program does. Returns at once unless the flag is there; with it, never returns: it waits
    /// for the parent to end, undoes, and exits. No window, no `NSApplication`, no settings: none of the app's start-up
    /// runs in a watchdog.
    static func runIfRequested(_ arguments: [String]) {
        guard arguments.contains(argument) else { return }
        // The flag with arguments nobody can read is a bug in whoever started this. It must not fall through to a second
        // whole Anode, so it ends.
        guard let request = parse(arguments) else { exit(2) }

        // Its own session: a Ctrl-C or a hang-up of the terminal Anode was started from reaches Anode and everything in
        // its group, and a watchdog caught in that would end with Anode and undo nothing.
        _ = setsid()
        // SIGTERM is how Anode's `stop()` ends it, with no undoing, and the default action does exactly that. A program
        // starts with the signal dispositions and mask of whoever started it, so they are set rather than assumed.
        signal(SIGTERM, SIG_DFL)
        var unblock = sigset_t()
        sigemptyset(&unblock)
        sigaddset(&unblock, SIGTERM)
        sigprocmask(SIG_UNBLOCK, &unblock, nil)

        switch waitForExit(of: request.parent, timeout: nil) {
        case .exited:
            undo(from: UltraRecordFile(url: URL(fileURLWithPath: request.recordPath)),
                 freezer: LiveProcessFreezer(), backlight: DisplayServicesBacklight())
            exit(0)
        case .timedOut, .failed:
            // The kernel would not say when Anode ends. Undoing now, with Anode very likely alive, would continue
            // apps it means to keep stopped; the record is still there for the next launch.
            exit(1)
        }
    }

    /// `["Anode", "--ultra-watchdog", "123", "/x/y.json"]` is (123, "/x/y.json"); anything else is nil. The program's own
    /// path comes first, as in `CommandLine.arguments`.
    static func parse(_ arguments: [String]) -> Request? {
        guard arguments.count == 4, arguments[1] == argument,
              let parent = pid_t(arguments[2]), !arguments[3].isEmpty else { return nil }
        // 0 is Anode's own group and 1 is launchd, which never ends: no parent a watchdog can wait for.
        guard parent > 1 else { return nil }
        return Request(parent: parent, recordPath: arguments[3])
    }

    /// Continues what the record names and puts the brightness back; the rest of the record is for the next launch.
    /// Nothing here clears the record: the next launch reads it to finish the undo.
    static func undo(record: UltraRecord, freezer: ProcessFreezing, backlight: BacklightControl) {
        let brightnessNow = record.brightnessBefore == nil ? nil : backlight.brightness()
        for action in UltraRecovery.actions(for: record, brightnessNow: brightnessNow) {
            switch action {
            case .resume(let pid, let startTime):
                _ = freezer.resume(pid: pid, startTime: startTime)
            case .brightness(let value):
                _ = backlight.setBrightness(value)
            case .unhide, .restoreRate, .keyboard, .powerMode:
                break
            }
        }
    }

    /// The same, from where the record is kept. No record, or one that cannot be read, is nothing to undo.
    static func undo(from store: UltraRecordStoring, freezer: ProcessFreezing, backlight: BacklightControl) {
        guard let record = store.load() else { return }
        undo(record: record, freezer: freezer, backlight: backlight)
    }

    /// Blocks until `pid` ends, with a kernel event (`kqueue`, `NOTE_EXIT`): the process sleeps until the kernel says so
    /// and uses no time of its own. A `pid` that is already gone counts as ended. `timeout` nil waits forever.
    static func waitForExit(of pid: pid_t, timeout: TimeInterval?) -> Wait {
        let queue = kqueue()
        guard queue >= 0 else { return .failed }
        defer { close(queue) }

        var change = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                            fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
        let deadline = timeout.map { DispatchTime.now().uptimeNanoseconds + UInt64(max(0, $0) * 1_000_000_000) }
        while true {
            var event = kevent()
            var remaining = timespec()
            if let deadline {
                let now = DispatchTime.now().uptimeNanoseconds
                let left = deadline > now ? deadline - now : 0
                remaining = timespec(tv_sec: Int(left / 1_000_000_000), tv_nsec: Int(left % 1_000_000_000))
            }
            // The request and the wait are one call. A pid that is gone is reported as an event with `EV_ERROR` and
            // `ESRCH` in `data`, or as a failed call with `errno` `ESRCH`: both mean the process is not there.
            let count = deadline == nil ? kevent(queue, &change, 1, &event, 1, nil)
                                        : kevent(queue, &change, 1, &event, 1, &remaining)
            if count < 0 {
                if errno == EINTR { continue }
                return errno == ESRCH ? .exited : .failed
            }
            if count == 0 { return .timedOut }
            if event.flags & UInt16(EV_ERROR) != 0 { return event.data == Int(ESRCH) ? .exited : .failed }
            return .exited
        }
    }
}
