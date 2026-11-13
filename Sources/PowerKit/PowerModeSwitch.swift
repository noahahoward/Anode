import Foundation

// ── macOS's Low Power Mode, as the root helper changes it ───────────────────
//
// Two commands (`FanCommand.enterLowPowerMode`, `.restorePowerMode`) and one tool: `/usr/bin/pmset`.
//
// WHAT RUNS. Exactly one program, at an absolute path, never through a shell, with a bounded wait and its output captured,
// through one runner the server is handed (`PowerModeRunner`). Only the helper's own `main` hands it the real one
// (`SystemPowerModeRunner`); a server built anywhere else, a test least of all, has no runner and refuses both commands.
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
    /// Run the tool with exactly `arguments` and wait at most `limit` seconds. nil when it could not be started or did not
    /// finish in time.
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

    var message: String {
        switch self {
        case .cannotChange:   return "this helper cannot change the power mode"
        case .noLowPowerMode: return "this Mac has no Low Power Mode"
        case .unreadable:     return "the Mac's power mode could not be read"
        case .notUnderstood:  return "the Mac's power mode is not one this helper knows"
        case .notTaken:       return "macOS did not take the power mode"
        case .badValue:       return "refused: that is not a power mode to put back"
        }
    }
}

/// Everything the helper does to the power mode, through the one runner.
struct PowerModeSwitch {
    let runner: PowerModeRunner

    /// How long each call to the tool may take. The app's link gives the helper two seconds to answer a request and
    /// closes the socket after that, which hands everything back (the helper then puts the mode back itself, having
    /// remembered it before its first write).
    ///
    /// An enter that goes through, a restore, and the put-back when a client goes make three calls each (a read and two
    /// writes): 1.8 s on this bound, inside the link's two seconds. A switch-on that fails and is rolled back can make six
    /// (a read and two writes, then a read and two writes, when a write that was reported failed had in fact landed): 3.6 s,
    /// past it. The answer to that one may find the socket closed; nothing is left on.
    static let callLimit: TimeInterval = 0.6

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
}

/// A child process, as far as ending one goes. What is done with a child that has not ended is decided in
/// `SystemPowerModeRunner.end`, on this, so that a test can drive it with a fake and no process.
protocol PowerModeChild: AnyObject {
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

    private let path: String

    public init() { path = Self.tool }

    /// For the tests alone, which hand it a harmless program of their own.
    init(path: String) { self.path = path }

    /// Ask `child` to end; if it is still running when the grace is up (`exitedWithin` waits for it to end for that
    /// long, and says whether it did), kill it. A child that ended while the grace ran out is not signalled: its pid
    /// may already be someone else's.
    static func end(_ child: PowerModeChild, grace: TimeInterval, exitedWithin: (TimeInterval) -> Bool) {
        guard child.isRunning else { return }
        child.terminate()
        if exitedWithin(grace) { return }
        guard child.isRunning else { return }
        child.kill()
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
            Self.end(RunningProcess(process), grace: Self.endGrace) { exited.wait(timeout: .now() + $0) == .success }
            return nil
        }
        guard !output.failed else { return nil }
        return PowerModeRun(status: process.terminationStatus, output: String(decoding: output.data, as: UTF8.self))
    }

    private final class RunningProcess: PowerModeChild {
        private let process: Process
        init(_ process: Process) { self.process = process }
        var isRunning: Bool { process.isRunning }
        func terminate() { process.terminate() }
        func kill() { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
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
