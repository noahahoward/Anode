import Foundation

// ── macOS's Low Power Mode, as the root helper changes it ───────────────────
//
// Three commands (`FanCommand.enterLowPowerMode`, `.restorePowerMode`, `.powerModeResult`) and one tool: `/usr/bin/pmset`.
//
// THE TOOL RUNS OFF THE LOOP. `pmset` can take seconds when it hangs, and the helper's loop answers the app within its link's
// two seconds, keeps the charger's floor and serves the plan: it never waits for the tool. Every job (the read, the writes, a
// roll-back, a put-back) runs on one serial queue of the helper's own (`PowerModeWorker`), through the one runner below.
// The loop hands it values and reads the finished outcome from a notice, the way it reads the plan's timer; what the helper
// remembers, what is owed and what the client was last told are the loop's alone (`FanHelperServer`). `enterLowPowerMode` and
// `restorePowerMode` answer at once ("started"), and the client asks `powerModeResult` for how it ended.
//
// WHAT RUNS. Exactly one program, at an absolute path, never through a shell, with a bounded wait and its output captured,
// through one runner the server is handed (`PowerModeRunner`). Only the helper's own `main` hands it the real one
// (`SystemPowerModeRunner`); a server built anywhere else, a test least of all, has no runner and refuses the commands.
// The arguments are built here and nowhere else, from closed sets: `-g custom` to read; to write, `-b` or `-c`, one of two
// key names, and one digit that has been checked against that key. Nothing in a command line comes from what the tool
// printed, and nothing from the client but a number that is validated before anything runs.
//
// WHAT IT TOUCHES. The power mode of the battery and of the charger, and nothing else. A source already in low power
// is not written, and is left as it was at the end. A source that no longer reads low power when the mode is put back is
// the owner's own choice since, and is left as it is: only what this feature changed is ever put back.
//
// WHICH KEY. `pmset -g custom` prints, for each power source the Mac has, either `powermode` (0 automatic, 1 low power,
// 2 high power) or, on a Mac without it, `lowpowermode` (0 off, 1 on). The Mac's own is read every time, because a value
// the app remembers is in the terms of whatever key the Mac had when it was read, and the key is what a command line needs.

/// What the tool printed and how it ended.
public struct PowerModeRun: Equatable {
    public let status: Int32
    public let output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }
}

/// How the helper runs `pmset`. The real one is `SystemPowerModeRunner`; a server is given none unless told, and the tests
/// give it a table in memory.
public protocol PowerModeRunner: AnyObject {
    /// Run the tool with exactly `arguments`, giving it `limit` seconds to finish. nil when it could not be started or did
    /// not finish in time. A tool that has not finished is ended, and ending it takes longer still: the real runner is
    /// back within `limit` plus `SystemPowerModeRunner.endGrace` plus `SystemPowerModeRunner.killWait`
    /// (`PowerModeSwitch.slowestCall` for the limit the helper uses), not within `limit`.
    func run(_ arguments: [String], within limit: TimeInterval) -> PowerModeRun?
}

/// A power source, as `pmset` names it: the flag to write it with and the heading it is read under.
enum PowerSource: CaseIterable {
    case battery, charger

    var flag: String { self == .battery ? "-b" : "-c" }
    var heading: String { self == .battery ? "Battery Power" : "AC Power" }
}

/// The key `pmset -g custom` lists for the power mode on this Mac.
enum PowerModeKey: String, CaseIterable {
    /// 0 automatic, 1 low power, 2 high power.
    case powermode
    /// 0 off, 1 on.
    case lowpowermode

    var highest: Int { self == .powermode ? 2 : 1 }
    /// Low power, in either key's terms.
    static let low = 1
}

/// The power mode of the battery and of the charger, as one number: `battery + 10 * charger`, each digit in the terms of
/// the key this Mac has (0…2).
public struct PowerModes: Equatable {
    public let battery: Int
    public let charger: Int

    public init?(battery: Int, charger: Int) {
        guard (0...2).contains(battery), (0...2).contains(charger) else { return nil }
        self.battery = battery
        self.charger = charger
    }

    public init?(packed: Int) {
        guard (0...22).contains(packed) else { return nil }
        self.init(battery: packed % 10, charger: packed / 10)
    }

    public var packed: Int { battery + 10 * charger }

    func digit(of source: PowerSource) -> Int { source == .battery ? battery : charger }
}

/// What `pmset -g custom` says about the power mode, for each source the Mac has.
struct PowerModeReading: Equatable {
    let key: PowerModeKey
    /// nil: the Mac has no such source (a desktop has no battery).
    let battery: Int?
    let charger: Int?

    func value(of source: PowerSource) -> Int? { source == .battery ? battery : charger }

    /// The reading as `PowerModes`, when every value it has is one this key takes. A source the Mac has not packs as 0.
    var modes: PowerModes? {
        for source in PowerSource.allCases {
            if let value = value(of: source), !(0...key.highest).contains(value) { return nil }
        }
        return PowerModes(battery: battery ?? 0, charger: charger ?? 0)
    }

    /// nil when no source lists either key: the Mac has no Low Power Mode. `powermode` wins on a Mac that lists both. A
    /// section that is neither the battery's nor the charger's (a UPS) is left out; a word that is not exactly a key
    /// followed by a number is not a reading.
    static func parse(_ output: String) -> PowerModeReading? {
        var section: PowerSource?
        var found: [PowerModeKey: [PowerSource: Int]] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let text = String(line).trimmingCharacters(in: .whitespaces)
            if text.hasSuffix(":") {
                let heading = String(text.dropLast())
                section = PowerSource.allCases.first { $0.heading == heading }
                continue
            }
            let words = text.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let section, words.count >= 2, let key = PowerModeKey(rawValue: String(words[0])),
                  let value = Int(words[1]) else { continue }
            found[key, default: [:]][section] = value
        }
        guard let key = [PowerModeKey.powermode, .lowpowermode].first(where: { found[$0] != nil }) else { return nil }
        return PowerModeReading(key: key, battery: found[key]?[.battery], charger: found[key]?[.charger])
    }
}

/// Why a power mode command was not done. The words are the reply's, and the app only ever tests whether it was done.
enum PowerModeRefusal: Error, Equatable {
    /// The helper was built without a runner.
    case cannotChange
    case noLowPowerMode
    case unreadable
    /// A value the Mac reports that is not one of the key's.
    case notUnderstood
    case notTaken
    /// A value to put back that is not a power mode (checked before the tool is run), or that this Mac's key does not take.
    case badValue
    /// A job is already running: one at a time. A put-back that is owed is one (it is on the worker, or it is the switch-on
    /// that says what there is to put back).
    case busy
    /// `powerModeResult` from a client that has not started anything.
    case nothingAsked

    var message: String {
        switch self {
        case .cannotChange:   return "this helper cannot change the power mode"
        case .noLowPowerMode: return "this Mac has no Low Power Mode"
        case .unreadable:     return "the Mac's power mode could not be read"
        case .notUnderstood:  return "the Mac's power mode is not one this helper knows"
        case .notTaken:       return "macOS did not take the power mode"
        case .badValue:       return "refused: that is not a power mode to put back"
        case .busy:           return "a power mode change is already running"
        case .nothingAsked:   return "no power mode change has been asked for"
        }
    }
}

/// Everything the helper does to the power mode, through the one runner.
struct PowerModeSwitch {
    let runner: PowerModeRunner

    /// How long the tool is given to finish each call. A call that has not finished is ended, and that takes more: it is
    /// asked to end and given `SystemPowerModeRunner.endGrace`, then killed and given `SystemPowerModeRunner.killWait` to be
    /// gone. So the longest a call can take is `slowestCall`, 0.6 + 0.2 + 0.2 = 1.0 s, not 0.6 s.
    ///
    /// This is the WORKER's time, not the loop's: the loop never waits for a call (see the header). What it bounds is how
    /// long a job holds the one worker, and so how long the helper stays up for it (`slowestCommand`,
    /// `slowestRolledBackEnter`), and what the helper's stop waits for.
    static let callLimit: TimeInterval = 0.6

    /// The longest one call to the real runner can take: what the tool is given, what it is given to end when asked, and
    /// what it is given to be gone once killed.
    static let slowestCall: TimeInterval = callLimit + SystemPowerModeRunner.endGrace + SystemPowerModeRunner.killWait

    /// The slowest a restore, or the put-back when a client goes, can be: a read and the two writes it makes (each source
    /// is tried). A read that has to be ended is no answer and ends the command, so in a command that goes on the read
    /// finished in the time it was given, `callLimit`; each write can have had to be ended, `slowestCall`. 0.6 + 1.0 + 1.0
    /// = 2.6 s. It is how long the helper's stop waits for the worker (`FanHelperServer.powerModeStopWait`): the mode is
    /// put back before the process ends if the worker can do it in that time, and the stop goes on without it otherwise.
    static let slowestCommand: TimeInterval = callLimit + 2 * slowestCall

    /// The slowest switch-on that fails and is rolled back, as the code can really go. The read finishes (0.6 s); the first
    /// write goes (0.6 s, it had to finish for the second to be tried); the second is cut off (1.0 s) and may have landed;
    /// the roll-back's read finishes (0.6 s); and both put-back writes are cut off (1.0 s each). Six calls:
    /// 0.6 + 0.6 + 1.0 + 0.6 + 1.0 + 1.0 = 4.8 s. A read that has to be ended, or a first write that is, ends the command
    /// sooner. The most the worker is held by one job; the app watches for its answer for longer than this.
    static let slowestRolledBackEnter: TimeInterval = callLimit + callLimit + slowestCall + callLimit + 2 * slowestCall

    /// How many times a put-back that fails is tried before the helper stops owing it, counting the first. Each try is a
    /// job of its own on the worker, started from the result of the one before (never on a timer), so a put-back that
    /// keeps failing keeps the helper up for at most this many `slowestCommand`s; after that it is idle again. What the
    /// helper remembers is kept, and the helper's stop tries once more.
    static let putBackTries = 2

    static let readArguments = ["-g", "custom"]

    /// The command line for one write, or nil when the digit is not one the key takes. Built from a closed set of flags,
    /// the key's own name, and the digit: nothing else can reach it.
    static func arguments(setting digit: Int, of key: PowerModeKey, for source: PowerSource) -> [String]? {
        guard (0...key.highest).contains(digit) else { return nil }
        return [source.flag, key.rawValue, String(digit)]
    }

    func read() -> Result<PowerModeReading, PowerModeRefusal> {
        guard let run = runner.run(Self.readArguments, within: Self.callLimit), run.status == 0 else {
            return .failure(.unreadable)
        }
        guard let reading = PowerModeReading.parse(run.output) else { return .failure(.noLowPowerMode) }
        return .success(reading)
    }

    private func write(_ digit: Int, of key: PowerModeKey, for source: PowerSource) -> Bool {
        guard let arguments = Self.arguments(setting: digit, of: key, for: source) else { return false }
        return runner.run(arguments, within: Self.callLimit)?.status == 0
    }

    /// Low power for every source that is not in it already. False as soon as a write is not taken: what was written
    /// stays, and the caller puts it back.
    func lower(_ reading: PowerModeReading) -> Bool {
        for source in PowerSource.allCases {
            guard let now = reading.value(of: source), now != PowerModeKey.low else { continue }
            guard write(PowerModeKey.low, of: reading.key, for: source) else { return false }
        }
        return true
    }

    /// Put `modes` back, on every source that still reads low power and was not in it before. The Mac is read again
    /// first: the key is its own, and a source that no longer reads low power is not this feature's to change. Every
    /// source is tried even when one is refused.
    func putBack(_ modes: PowerModes) -> Result<Void, PowerModeRefusal> {
        let reading: PowerModeReading
        switch read() {
        case .failure(let why): return .failure(why)
        case .success(let seen): reading = seen
        }
        // A 2 where the key has only off and on is not a value to write: refused before anything is.
        for source in PowerSource.allCases where reading.value(of: source) != nil {
            guard modes.digit(of: source) <= reading.key.highest else { return .failure(.badValue) }
        }
        var clean = true
        for source in PowerSource.allCases {
            guard reading.value(of: source) == PowerModeKey.low else { continue }
            let wanted = modes.digit(of: source)
            if wanted != PowerModeKey.low, !write(wanted, of: reading.key, for: source) { clean = false }
        }
        return clean ? .success(()) : .failure(.notTaken)
    }

    /// One whole job, as the worker runs it: values in (what the loop remembers), values out (what happened, and what the
    /// loop is to remember). Nothing here touches the loop's books or says anything: the loop does both from the outcome.
    func perform(_ job: PowerModeJob) -> PowerModeOutcome {
        switch job {
        case .enter(let held): return enter(held: held)
        case .putBack(let modes):
            switch putBack(modes) {
            case .success: return .putBack
            case .failure(let why): return .refused(why, memory: .unchanged)
            }
        }
    }

    /// What was read is the "before", unless the client already holds a mode: what the Mac reads then is its own work. Any
    /// write that is not taken is put back; what is remembered is forgotten only when that has worked.
    private func enter(held: PowerModes?) -> PowerModeOutcome {
        let reading: PowerModeReading
        switch read() {
        case .failure(let why): return .refused(why, memory: .unchanged)
        case .success(let seen): reading = seen
        }
        let before: PowerModes
        if let held {
            before = held
        } else if let seen = reading.modes {
            before = seen
        } else {
            return .refused(.notUnderstood, memory: .unchanged)
        }
        guard lower(reading) else {
            if case .success = putBack(before) { return .refused(.notTaken, memory: .forget) }
            return .refused(.notTaken, memory: .remember(before))
        }
        return .on(before: before)
    }
}

/// What the loop hands the worker, as values.
enum PowerModeJob: Equatable {
    /// Read the Mac, switch Low Power Mode on for every source that is not in it, and say what it was. `held` is what the
    /// loop already remembers for the client (nil: nothing).
    case enter(held: PowerModes?)
    /// Put these modes back, wherever a source still reads low power and was not in it before. A client's restore, and the
    /// put-back owed when a client goes or the helper stops, are the same work.
    case putBack(PowerModes)
}

/// What the worker hands back, as values.
enum PowerModeOutcome: Equatable {
    /// What the loop is to remember after the job.
    enum Memory: Equatable {
        case unchanged
        case remember(PowerModes)
        case forget
    }

    /// Switched on; the Mac was `before`. Remembered until it is put back.
    case on(before: PowerModes)
    /// Put back. Nothing is remembered any more.
    case putBack
    case refused(PowerModeRefusal, memory: Memory)

    var memory: Memory {
        switch self {
        case .on(let before): return .remember(before)
        case .putBack: return .forget
        case .refused(_, let memory): return memory
        }
    }
}

/// The one serial queue every power-mode job runs on, so that the helper's loop never waits for the tool. Owned by the
/// server, which gives it a job at a time (it refuses a second while one runs) and reads each outcome from a notice.
final class PowerModeWorker {
    private let queue = DispatchQueue(label: "dev.anode.helper.power-mode")
    private let machine: PowerModeSwitch
    private let outstanding = DispatchGroup()

    init(_ machine: PowerModeSwitch) { self.machine = machine }

    /// Run `job` after the ones already given. `done` gets the outcome on the worker's queue, and must only hand it to the
    /// loop: it posts a notice and writes the wake pipe, as the plan's timer does.
    func submit(_ job: PowerModeJob, done: @escaping (PowerModeOutcome) -> Void) {
        outstanding.enter()
        queue.async { [machine, outstanding] in
            done(machine.perform(job))
            outstanding.leave()
        }
    }

    /// True when every job given has run and been handed on, false when `timeout` ran out first.
    func idle(within timeout: TimeInterval) -> Bool {
        outstanding.wait(timeout: .now() + timeout) == .success
    }
}

/// A child process, as far as ending one goes. What is done with a child that has not ended is decided in
/// `SystemPowerModeRunner.end`, on this, so that a test can drive it with a fake and no process.
protocol PowerModeChild: AnyObject {
    var processIdentifier: Int32 { get }
    var isRunning: Bool { get }
    /// Ask it to end (SIGTERM).
    func terminate()
    /// Make it end (SIGKILL), to this child's own pid and nothing else.
    func kill()
}

/// The real runner. Never built by anything but the helper's `main`, and never called by a test for `pmset`.
///
/// A child process with no shell, its output read on a thread of its own, and the child ended if it has not finished
/// within the limit. THE REQUEST TO END IS NOT ENOUGH: the helper ignores SIGTERM (and the other signals it routes to
/// `stop()`) so that a signal cannot end it before its loop has handed everything back, and what a process ignores is
/// inherited by what it runs, so a hung `pmset` may ignore the request too. A child still there after a short grace is
/// killed.
public final class SystemPowerModeRunner: PowerModeRunner {

    /// The one program the helper runs. An absolute path, so nothing is looked up on a path someone else can write to.
    public static let tool = "/usr/bin/pmset"

    /// How long a child that was asked to end has before it is made to.
    static let endGrace: TimeInterval = 0.2

    /// How long a child that was killed is waited for. The kill is not waited out for ever: a child that is still there
    /// then is said, and the call goes on.
    static let killWait: TimeInterval = 0.2

    /// A pid that may be sent a signal. `kill(-1, SIGKILL)` as root ends every process the user can see, `kill(0, ...)` the
    /// whole process group, and pid 1 is launchd: none of them is ever a child of this.
    static func mayBeSignalled(_ pid: Int32) -> Bool { pid > 1 }

    private let path: String

    public init() { path = Self.tool }

    /// For the tests alone, which hand it a harmless program of their own.
    init(path: String) { self.path = path }

    /// Ask `child` to end; if it is still running when the grace is up (`exitedWithin` waits for it to end for that
    /// long, and says whether it did), kill it, and wait for it to be gone for `killWait`: if it is still there then, say
    /// so once through `log` and go on. A child that ended while a wait ran out is not signalled again: its pid may
    /// already be someone else's. A pid that may not be signalled (`mayBeSignalled`) is not signalled at all. Takes
    /// `grace` plus `killWait` at most.
    static func end(_ child: PowerModeChild, grace: TimeInterval = endGrace,
                    killWait: TimeInterval = SystemPowerModeRunner.killWait,
                    exitedWithin: (TimeInterval) -> Bool, log: (String) -> Void) {
        guard mayBeSignalled(child.processIdentifier), child.isRunning else { return }
        child.terminate()
        if exitedWithin(grace) { return }
        guard child.isRunning else { return }
        child.kill()
        if exitedWithin(killWait) { return }
        guard child.isRunning else { return }
        log("WARNING: pmset (pid \(child.processIdentifier)) was still running \(String(format: "%.1f", killWait)) s after "
          + "SIGKILL; going on without it")
    }

    public func run(_ arguments: [String], within limit: TimeInterval) -> PowerModeRun? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }

        // Read with the call that throws: an error is no answer. (`availableData` raises an exception on a read error,
        // and nothing can catch that.) The pipe is held until the reader is done, so its descriptor is never closed under
        // a read that is still waiting for a child that has been killed.
        let output = Output()
        let atEnd = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                while let chunk = try pipe.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
                    output.append(chunk)
                }
            } catch {
                output.fail()
            }
            atEnd.signal()
        }

        let deadline = DispatchTime.now() + limit
        guard atEnd.wait(timeout: deadline) == .success, exited.wait(timeout: deadline) == .success else {
            Self.end(RunningProcess(process),
                     exitedWithin: { exited.wait(timeout: .now() + $0) == .success },
                     log: { line in fanLog.error("helper: \(line, privacy: .public)") })
            return nil
        }
        guard !output.failed else { return nil }
        return PowerModeRun(status: process.terminationStatus, output: String(decoding: output.data, as: UTF8.self))
    }

    private final class RunningProcess: PowerModeChild {
        private let process: Process
        init(_ process: Process) { self.process = process }
        var processIdentifier: Int32 { process.processIdentifier }
        var isRunning: Bool { process.isRunning }
        func terminate() { process.terminate() }
        func kill() {
            let pid = process.processIdentifier
            guard SystemPowerModeRunner.mayBeSignalled(pid) else { return }
            _ = Darwin.kill(pid, SIGKILL)
        }
    }

    private final class Output {
        private let lock = NSLock()
        private var bytes = Data()
        private var failedRead = false
        func append(_ chunk: Data) { lock.lock(); bytes.append(chunk); lock.unlock() }
        func fail() { lock.lock(); failedRead = true; lock.unlock() }
        var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
        var failed: Bool { lock.lock(); defer { lock.unlock() }; return failedRead }
    }
}
