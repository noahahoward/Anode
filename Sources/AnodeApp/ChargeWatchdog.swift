import Darwin
import Foundation
import PowerKit

/// The watchdog of Charge Control: a child of Anode that puts macOS's own charge settings back at once if Anode ends
/// without quitting.
///
/// macOS keeps a charge limit it was given after the app that set it is gone. A quit puts macOS back, and a launch
/// after a run that did not quit lifts the limit first (`ChargeController.liftAtLaunch`), but an Anode that crashed, or
/// was force quit, and is never opened again would leave the limit in force for good. So while Charge Control holds
/// the limit, Anode starts itself again with `--charge-watchdog <its pid>`. That process does nothing and costs nothing
/// until Anode's pid exits (it sleeps in the kernel until the event arrives, it does not poll). Then, if the record
/// still names that Anode as a holder (it never released), it does what the next launch would have done: macOS's own
/// settings go back, by the same restore and the same holder rule, and the start after the next launch waits out its
/// delay.
///
/// A normal end is Anode's job, not the watchdog's: `stop()` ends it with `stopSignal` and it exits without lifting.
/// SIGTERM is not that signal, and is ignored: whatever sends it to everything called AnodeApp ends Anode without a
/// quit, which is exactly when the watchdog has to stay. It never outlives Anode by more than the restore takes.
protocol ChargeWatchdogging: AnyObject {
    /// True only when a watchdog process is running after the call (one running already counts).
    @discardableResult func start() -> Bool
    /// Ends it without lifting. Does nothing when none runs.
    func stop()
}

// ── Anode's side ────────────────────────────────────────────────────────────

/// Starts and stops the watchdog from Anode. Called from the main thread, by the controller.
final class LiveChargeWatchdog: ChargeWatchdogging {

    private let log: (String) -> Void
    private let launch: (_ arguments: [String]) throws -> WatchdogProcess
    private let signal: (_ pid: pid_t, _ signal: Int32) -> Void
    private var process: WatchdogProcess?

    /// `launch` starts this program again with the arguments it is given and throws when it cannot; `signal` sends a
    /// signal to a process. Tests replace both, so no process is started and none is signalled.
    init(log: @escaping (String) -> Void = { FeatureLog.append("charge.log", $0) },
         launch: @escaping (_ arguments: [String]) throws -> WatchdogProcess = LiveUltraWatchdog.launchThisProgram,
         signal: @escaping (_ pid: pid_t, _ signal: Int32) -> Void = { _ = kill($0, $1) }) {
        self.log = log
        self.launch = launch
        self.signal = signal
    }

    @discardableResult
    func start() -> Bool {
        if let process, process.isRunning { return true }
        process = nil
        do {
            let child = try launch(ChargeWatchdog.arguments(parent: getpid()))
            // Launched is not the same as running: one that has ended already is not a watchdog.
            guard child.isRunning else {
                log("charge watchdog: it ended as soon as it was started")
                return false
            }
            process = child
            return true
        } catch {
            log("charge watchdog: could not start (\(error.localizedDescription))")
            return false
        }
    }

    func stop() {
        guard let child = process else { return }
        process = nil
        if child.isRunning { signal(child.pid, ChargeWatchdog.stopSignal) }
    }
}

// ── The watchdog itself ─────────────────────────────────────────────────────

enum ChargeWatchdog {

    static let argument = "--charge-watchdog"

    /// How Anode ends its watchdog: the default action of this signal, which ends the process with nothing lifted.
    static let stopSignal = SIGUSR1

    /// How many times the record is looked at when it cannot be read (another Anode is in the middle of its own
    /// restore and holds the lock), and how long apart.
    static let recordLooks = 5
    static let recordLookInterval: TimeInterval = 1

    /// What the program is started with, after its own path. `parse` reads it back.
    static func arguments(parent: pid_t) -> [String] { [argument, String(parent)] }

    /// `["Anode", "--charge-watchdog", "123"]` is 123; anything else is nil. The program's own path comes first, as in
    /// `CommandLine.arguments`. 0 is Anode's own group and 1 is launchd, which never ends: no parent to wait for.
    static func parse(_ arguments: [String]) -> pid_t? {
        guard arguments.count == 3, arguments[1] == argument, let parent = pid_t(arguments[2]), parent > 1 else {
            return nil
        }
        return parent
    }

    /// Among the first things the program does. Returns at once unless the flag is there; with it, never returns: it
    /// waits for the parent to end, lifts, and exits. No window and no `NSApplication`: none of the app's start-up runs
    /// in a watchdog.
    static func runIfRequested(_ arguments: [String]) {
        guard arguments.contains(argument) else { return }
        // The flag with arguments nobody can read is a bug in whoever started this. It must not fall through to a
        // second whole Anode, so it ends.
        guard let parent = parse(arguments) else { exit(2) }

        // Its own session: a Ctrl-C or a hang-up of the terminal Anode was started from reaches Anode and everything
        // in its group, and a watchdog caught in that would end with Anode and lift nothing.
        _ = setsid()
        // A program starts with the signal dispositions and mask of whoever started it, so they are set, not assumed.
        signal(stopSignal, SIG_DFL)
        signal(SIGTERM, SIG_IGN)
        var unblock = sigset_t()
        sigemptyset(&unblock)
        sigaddset(&unblock, stopSignal)
        sigprocmask(SIG_UNBLOCK, &unblock, nil)

        switch UltraWatchdog.waitForExit(of: parent, timeout: nil, confirm: {
            !UltraWatchdog.parentHasEnded(given: parent, current: getppid())
        }) {
        case .exited:
            ChargeController.liftAfterAnodeEnded(pid: parent, records: ChargeRecords.live())
            exit(0)
        case .timedOut, .failed:
            // The kernel would not say when Anode ends. Lifting now, with Anode very likely alive, would take away a
            // limit it means to hold; the record is still there for the next launch.
            exit(1)
        }
    }
}
