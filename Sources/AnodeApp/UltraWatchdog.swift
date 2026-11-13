import Darwin
import Foundation
import PowerKit

/// The watchdog of Ultra Low Power Mode: a child of Anode that continues every frozen app at once if Anode dies.
///
/// A frozen app stays frozen for good if nobody continues it, and Anode is the one that does. So while the mode is on,
/// Anode starts itself again with `--ultra-watchdog <its pid> <the record's path>`. That process does nothing and
/// costs nothing until Anode's pid exits (it sleeps in the kernel until the event arrives, it does not poll). Then it
/// reads the record and undoes what it can without a window, an app or any setting of Anode's: continuing what the
/// record names, lifting the background policy that kept the apps on the efficiency cores (from what the record names and from
/// what those processes started since, found in a process table it reads itself), and putting the brightness back (after Low Power
/// Mode is off, when the mode asked for it). Unhiding, the refresh rate and the keyboard light are left for the next launch, which
/// reads the same record; the power mode is the helper's, which puts it back itself when Anode's connection closes. A record that
/// names nothing for a launch to do is taken away once the screen is done, so that a launch days later does not replay it.
///
/// A normal end is Anode's job, not the watchdog's: `stop()` ends it with SIGTERM and it exits without undoing.

protocol UltraWatchdogging: AnyObject {
    /// True only when a watchdog process is running after the call (one running already counts). False means nothing
    /// will continue the frozen apps if Anode dies, and the caller must not freeze anything on it.
    @discardableResult func start() -> Bool
    /// Ends it without undoing. Does nothing when none runs.
    func stop()
    /// The running watchdog's pid; nil when none runs, or after `stop()`. The controller keeps it out of the spin guard.
    var pid: pid_t? { get }
}

// ── Anode's side ────────────────────────────────────────────────────────────

/// The process a watchdog runs in, as far as Anode needs to know it. `Process` is one; a test has a stub.
protocol WatchdogProcess: AnyObject {
    var pid: pid_t { get }
    var isRunning: Bool { get }
    func terminate()
}

extension Process: WatchdogProcess {
    var pid: pid_t { processIdentifier }
}

/// Starts and stops the watchdog from Anode. Called from the main thread, by the controller.
final class LiveUltraWatchdog: UltraWatchdogging {

    private let recordURL: URL
    private let log: (String) -> Void
    private let launch: (_ arguments: [String]) throws -> WatchdogProcess
    private var process: WatchdogProcess?

    /// `launch` starts this program again with the arguments it is given and throws when it cannot. Tests replace it so
    /// no process is started.
    init(recordURL: URL, log: @escaping (String) -> Void = { _ in },
         launch: @escaping (_ arguments: [String]) throws -> WatchdogProcess = LiveUltraWatchdog.launchThisProgram) {
        self.recordURL = recordURL
        self.log = log
        self.launch = launch
    }

    /// What the program is started with, after its own path. `UltraWatchdog.parse` reads it back.
    static func arguments(parent: pid_t, recordURL: URL) -> [String] {
        [UltraWatchdog.argument, String(parent), recordURL.path]
    }

    var pid: pid_t? {
        guard let process, process.isRunning else { return nil }
        return process.pid
    }

    @discardableResult
    func start() -> Bool {
        if pid != nil { return true }
        process = nil
        do {
            let child = try launch(Self.arguments(parent: getpid(), recordURL: recordURL))
            // Launched is not the same as running: one that has ended already is not a watchdog.
            guard child.isRunning else {
                log("ultra watchdog: it ended as soon as it was started")
                return false
            }
            process = child
            return true
        } catch {
            // The record is on disk all the same, so the next launch can still finish the undo; but until then nothing
            // continues the apps if Anode dies, so the caller is told.
            log("ultra watchdog: could not start (\(error.localizedDescription))")
            return false
        }
    }

    func stop() {
        guard let child = process else { return }
        process = nil
        // `terminate()` on a process that has ended is for the system to refuse, not for this to find out.
        if child.isRunning { child.terminate() }
    }

    private struct NoExecutable: LocalizedError {
        var errorDescription: String? { "this program has no executable to start again" }
    }

    static func launchThisProgram(arguments: [String]) throws -> WatchdogProcess {
        guard let executable = Bundle.main.executableURL else { throw NoExecutable() }
        let child = Process()
        child.executableURL = executable
        child.arguments = arguments
        // Nothing of Anode's to hold on to: a pipe it shares with Anode would outlive Anode's end and keep the other
        // side of it open.
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        return child
    }
}

// ── The watchdog itself ─────────────────────────────────────────────────────

enum UltraWatchdog {

    static let argument = "--ultra-watchdog"

    /// How often the undo looks at whether macOS's Low Power Mode is off yet, before it puts the screen back.
    static let lowPowerPollSeconds: TimeInterval = 0.25
    /// The most it waits for Low Power Mode to go off: longer than a turning off waits, since Anode's connection to the helper has to
    /// close first. Past it the screen is put back all the same.
    static let lowPowerWaitSeconds: TimeInterval = 8
    /// After Low Power Mode is off, how long macOS is given to finish raising the screen by itself (measured, 0.3 to 0.5 s).
    static let brightnessSettleSeconds: TimeInterval = 1

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

        switch waitForExit(of: request.parent, timeout: nil,
                           confirm: { !parentHasEnded(given: request.parent, current: getppid()) }) {
        case .exited:
            // The backlight is built only when its turn comes, after every continue: its start-up and its first read
            // can stall on a Mac that is asleep, and nothing may hold up a continue.
            undo(from: UltraRecordFile(url: URL(fileURLWithPath: request.recordPath)),
                 freezer: LiveProcessFreezer(), throttler: LiveProcessThrottler(),
                 processTable: LiveProcessList.processTable, lowPowerOn: { ProcessInfo.processInfo.isLowPowerModeEnabled },
                 sleep: { Thread.sleep(forTimeInterval: $0) }, log: { FeatureLog.append("ultra.log", $0) },
                 backlight: DisplayServicesBacklight())
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

    /// Whether the process that started this one is gone: its parent is no longer the pid it was given. A process whose
    /// parent ends is re-parented (to launchd), which is how a watchdog started after Anode died sees it, and how it
    /// sees a pid that was reused since.
    static func parentHasEnded(given: pid_t, current: pid_t) -> Bool {
        current != given
    }

    /// Continues what the record names, lifts the background policy from every process it names and from every living child of
    /// one (a table read here finds them), and puts the brightness back; the rest of the record is for the next launch.
    /// Returns whether a launch has nothing left to do (`UltraRecord.leavesNothingForALaunch`, and everything under the policy
    /// lifted, and the screen done: put back, or left on purpose), which is what lets `undo(from:)` take the record away.
    ///
    /// Every continue comes first, then the policy, which a kept app would otherwise carry for as long as it runs. The brightness
    /// comes last: when the mode asked for Low Power Mode, it is looked at every `lowPowerPollSeconds` until it is off (or
    /// `lowPowerWaitSeconds` have passed) and macOS is given `brightnessSettleSeconds` to finish its own ramp first. `lowPowerOn`
    /// and `sleep` are given, so that a test reads a made-up Low Power Mode and never sleeps. A screen that is dark is left (with the
    /// lid shut the lid dimmer holds it at 0, and the watchdog has no `OwnBrightness` to ask), and `log` says so. The backlight is a
    /// parameter that is not evaluated until the brightness step, and the step is left out when the record has no brightness to put
    /// back.
    @discardableResult
    static func undo(record: UltraRecord, freezer: ProcessFreezing, throttler: ProcessThrottling,
                     processTable: () -> [UltraProcess]?, lowPowerOn: () -> Bool, sleep: (TimeInterval) -> Void,
                     log: (String) -> Void, backlight: @autoclosure () -> BacklightControl) -> Bool {
        let actions = UltraRecovery.actions(for: record, brightnessNow: nil)
        for case .resume(let pid, let startTime) in actions {
            _ = freezer.resume(pid: pid, startTime: startTime)
        }
        var lifted: [FreezeGroup.Member] = []
        for case .unthrottle(let pid, let startTime) in actions {
            _ = throttler.unthrottle(pid: pid, startTime: startTime)
            lifted.append(FreezeGroup.Member(pid: pid, startTime: startTime))
        }
        // What those processes started since the last sweep inherited the policy and is on no record: the table is read now, here,
        // and every living child of a process the record names (identity checked by start time) is lifted too. A table that cannot
        // be read leaves those children under it for a launch to lift.
        var childrenLifted = true
        if !lifted.isEmpty {
            if let table = processTable() {
                for child in UltraThrottle.descendants(of: lifted, in: table) {
                    _ = throttler.unthrottle(pid: child.pid, startTime: child.startTime)
                }
            } else {
                childrenLifted = false
            }
        }
        let nothingLeftForALaunch = childrenLifted && record.leavesNothingForALaunch
        guard let before = record.brightnessBefore else { return nothingLeftForALaunch }
        // The screen is last, after Low Power Mode is off: macOS raises it when Low Power Mode ends, so a level set before that is
        // lost. Nothing is waited for when Low Power Mode was the owner's own, or the helper was never asked.
        if record.waitsForLowPowerToEnd {
            var waited: TimeInterval = 0
            while lowPowerOn(), waited < lowPowerWaitSeconds {
                sleep(lowPowerPollSeconds)
                waited += lowPowerPollSeconds
            }
            sleep(brightnessSettleSeconds)
        }
        let panel = backlight()
        let now = panel.brightness()
        switch BrightnessCeiling.decide(before: before, now: now, leavingADarkScreen: true) {
        case .putBack(let level):
            // Refused: the screen is still where it was, and a launch can try again.
            guard panel.setBrightness(level) else {
                log("ultra watchdog: the screen did not take \(level2(level)), so it was not put back")
                return false
            }
            log("ultra watchdog: the screen was put back to \(level2(level))")
        case .couldNotBeRead:
            // No way to tell where it is; a launch may be able to read it.
            log("ultra watchdog: the screen could not be read, so it was not put back")
            return false
        case .screenIsDark:
            log("ultra watchdog: the screen is dark, so it was left")
        case .aboveTheCeiling:
            log("ultra watchdog: the screen was left at \(level2(now ?? 0)): it is above the ceiling, so something else raised it")
        case .alreadyAtTheEarlierLevel:
            log("ultra watchdog: the screen was left at \(level2(now ?? 0)): it is not dimmer than it was before the mode")
        case .nothingWasLowered:
            break
        }
        return nothingLeftForALaunch
    }

    /// The same, from where the record is kept. No record, or one that cannot be read, is nothing to undo. When a launch has nothing
    /// left to do the record is taken away, after the screen step and never before it: left, it would be replayed at the next launch,
    /// possibly days later (switching off a Low Power Mode the owner has turned on since, or raising a screen the owner has dimmed since).
    /// Only the record that was undone is taken: the screen step can last seconds, and a session started in that time has written its
    /// own. A record that names something for a launch (an app to unhide, the refresh rate, the keyboard light) is left, as it always was.
    static func undo(from store: UltraRecordStoring, freezer: ProcessFreezing, throttler: ProcessThrottling,
                     processTable: () -> [UltraProcess]?, lowPowerOn: () -> Bool, sleep: (TimeInterval) -> Void,
                     log: (String) -> Void, backlight: @autoclosure () -> BacklightControl) {
        guard let record = store.load() else { return }
        let done = undo(record: record, freezer: freezer, throttler: throttler, processTable: processTable, lowPowerOn: lowPowerOn,
                        sleep: sleep, log: log, backlight: backlight())
        guard done, store.load() == record else { return }
        store.clear()
    }

    /// A brightness for the log, with two decimals.
    private static func level2(_ value: Float) -> String { String(format: "%.2f", value) }

    /// Blocks until `pid` ends, with a kernel event (`kqueue`, `NOTE_EXIT`): the process sleeps until the kernel says so
    /// and uses no time of its own. A `pid` that is already gone counts as ended. `timeout` nil waits forever.
    ///
    /// `confirm` is asked once, after the event is registered, whether `pid` is still the process that was meant; false
    /// counts as ended. Asking after registering leaves no gap: from then on an end of that process is an event, and
    /// before it a pid that was reused is the one thing a registration could have caught.
    static func waitForExit(of pid: pid_t, timeout: TimeInterval?, confirm: () -> Bool = { true }) -> Wait {
        let queue = kqueue()
        guard queue >= 0 else { return .failed }
        defer { close(queue) }

        // Registering and waiting are two calls, so that the check sits between them. With no room for an event, a pid
        // that is gone comes back as a failed call with `errno` `ESRCH`; both forms below mean it is not there.
        var change = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                            fflags: UInt32(NOTE_EXIT), data: 0, udata: nil)
        while kevent(queue, &change, 1, nil, 0, nil) < 0 {
            if errno == EINTR { continue }
            return errno == ESRCH ? .exited : .failed
        }
        if !confirm() { return .exited }

        let deadline = timeout.map { DispatchTime.now().uptimeNanoseconds + UInt64(max(0, $0) * 1_000_000_000) }
        while true {
            var event = kevent()
            var remaining = timespec()
            if let deadline {
                let now = DispatchTime.now().uptimeNanoseconds
                let left = deadline > now ? deadline - now : 0
                remaining = timespec(tv_sec: Int(left / 1_000_000_000), tv_nsec: Int(left % 1_000_000_000))
            }
            let count = deadline == nil ? kevent(queue, nil, 0, &event, 1, nil)
                                        : kevent(queue, nil, 0, &event, 1, &remaining)
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
