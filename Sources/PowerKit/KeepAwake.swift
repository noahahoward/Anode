import Foundation
import IOKit.pwr_mgt

// ── Keep Awake ──────────────────────────────────────────────────────────────
//
// A Caffeine-style switch with two strengths:
//
//   Never Sleep         the Mac stays awake and its screen stays on while the lid is OPEN. Two power
//                       assertions, the same thing Caffeine and `caffeinate -d` take. No privileges.
//   Always Stay Awake   the same, and the Mac also keeps running with the lid CLOSED and nothing attached.
//                       Assertions cannot do that (a MacBook with no external display sleeps on lid close
//                       whatever is asserted), so this one flips `pmset -a disablesleep`, which needs root.
//
// `disablesleep` is the dangerous half. It is stored in the power settings, so it OUTLIVES this process and
// survives a reboot: an app that sets it and then crashes leaves a laptop that will not sleep in a bag. Every
// rule below exists to make sure that cannot be the outcome:
//
//   · stopping a session clears it, and quitting stops the session;
//   · if the clear fails, the fact that WE set it stays on disk and the next launch clears it again
//     (`reconcileAtLaunch`) — a flag set by someone's own `sudo pmset` is left alone, because that was theirs;
//   · Always Stay Awake switches itself off on battery at or below `lowBatteryPercent`;
//   · it never begins unless the privilege is already in place, so a failed write cannot be half done.
//
// The privilege is one narrow sudoers rule, installed once with an admin prompt and removable from the same
// place: it lets this user run exactly `pmset -a disablesleep 1` and `pmset -a disablesleep 0` as root, and
// nothing else. See `KeepAwakeAuthorisation`.
//
// Everything that touches the machine is behind a protocol, so every sequence — start, switch mode, expire,
// battery drain, crash and relaunch — is played in the tests without sleeping anything.

public enum KeepAwakeMode: String, CaseIterable {
    case neverSleep
    case alwaysAwake

    public var title: String {
        switch self {
        case .neverSleep:   return "Never Sleep"
        case .alwaysAwake:  return "Always Stay Awake"
        }
    }
    /// One line for the menu: what the mode does that the other does not.
    public var detail: String {
        switch self {
        case .neverSleep:   return "screen stays on while the lid is open"
        case .alwaysAwake:  return "keeps running with the lid closed"
        }
    }
}

/// The durations offered. `nil` seconds means until it is switched off.
public enum KeepAwakeDuration: Int, CaseIterable {
    case forever = 0
    case fifteenMinutes = 900
    case oneHour = 3600
    case fourHours = 14400

    public var seconds: TimeInterval? { self == .forever ? nil : TimeInterval(rawValue) }
    public var title: String {
        switch self {
        case .forever:         return "Until I turn it off"
        case .fifteenMinutes:  return "15 minutes"
        case .oneHour:         return "1 hour"
        case .fourHours:       return "4 hours"
        }
    }
}

public struct KeepAwakeSession: Equatable {
    public let mode: KeepAwakeMode
    public let started: Date
    public let endsAt: Date?
}

/// Why the last session ended, for the UI to say so when it was not the user.
public enum KeepAwakeStopReason: Equatable {
    case user
    case expired
    /// Always Stay Awake gave up on a low battery, at this percent.
    case lowBattery(Int)
    /// Turning `disablesleep` off failed; it is still on and will be retried at the next launch.
    case couldNotRestoreSleep
}

public enum KeepAwakeError: Error, Equatable {
    /// Always Stay Awake was asked for but the sudoers rule is not installed.
    case notAuthorised
    case assertionFailed
    case couldNotDisableSleep
}

// ── The machine, behind protocols ───────────────────────────────────────────

public protocol SleepAssertions: AnyObject {
    /// Hold "do not sleep, do not dim" until `release`. Replaces any hold already taken.
    func hold(reason: String) -> Bool
    func release()
}

public protocol ClosedLidSleepControl: AnyObject {
    /// `pmset`'s SleepDisabled, or nil if it could not be read.
    func sleepDisabled() -> Bool?
    /// Set it. True only if the machine now reports the requested value.
    func setSleepDisabled(_ on: Bool) -> Bool
    /// Whether `setSleepDisabled` can run without a password prompt right now.
    func isAuthorised() -> Bool
}

// ── The state machine ───────────────────────────────────────────────────────

public final class KeepAwake {

    /// Always Stay Awake turns itself off on battery at or below this charge.
    public static let lowBatteryPercent = 10
    /// The one persisted fact the safety net needs: this app, not a person, turned `disablesleep` on.
    static let weSetItKey = "keepAwake.weSetSleepDisabled"

    public private(set) var session: KeepAwakeSession?
    public private(set) var lastStop: KeepAwakeStopReason?
    /// Called on every change of `session` or `lastStop`.
    public var onChange: (() -> Void)?

    private let assertions: SleepAssertions
    private let lid: ClosedLidSleepControl
    private let defaults: UserDefaults
    private let now: () -> Date

    public init(assertions: SleepAssertions, lid: ClosedLidSleepControl,
                defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.assertions = assertions
        self.lid = lid
        self.defaults = defaults
        self.now = now
    }

    public var isActive: Bool { session != nil }

    /// True while a `disablesleep` this app turned on is still on.
    var weSetSleepDisabled: Bool { defaults.bool(forKey: Self.weSetItKey) }

    /// Begin (or switch to) `mode`. Throws without having changed anything if it cannot be done in full.
    public func start(_ mode: KeepAwakeMode, for duration: TimeInterval? = nil) throws {
        if mode == .alwaysAwake {
            guard lid.isAuthorised() else { throw KeepAwakeError.notAuthorised }
        }
        guard assertions.hold(reason: "Anode Keep Awake: \(mode.title)") else {
            throw KeepAwakeError.assertionFailed
        }
        switch mode {
        case .alwaysAwake:
            if !lid.setSleepDisabled(true) {
                // Do not leave the screen-on half running as though the request had worked.
                if session == nil { assertions.release() }
                throw KeepAwakeError.couldNotDisableSleep
            }
            defaults.set(true, forKey: Self.weSetItKey)
        case .neverSleep:
            // Coming down from Always Stay Awake: give the lid back its normal behaviour.
            if weSetSleepDisabled { _ = restoreSleep() }
        }
        let t = now()
        session = KeepAwakeSession(mode: mode, started: t, endsAt: duration.map { t.addingTimeInterval($0) })
        lastStop = nil
        onChange?()
    }

    public func stop(_ reason: KeepAwakeStopReason = .user) {
        assertions.release()
        var reason = reason
        if weSetSleepDisabled, !restoreSleep() { reason = .couldNotRestoreSleep }
        guard session != nil || reason != .user else { return }
        session = nil
        lastStop = reason
        onChange?()
    }

    /// Called every few seconds while a session runs, and on wake. Ends it if its time is up or the battery is low.
    /// `batteryPercent` is nil when there is no battery (a desktop), which never trips the check.
    public func tick(batteryPercent: Int?, onAC: Bool) {
        guard let s = session else { return }
        if let end = s.endsAt, now() >= end { stop(.expired); return }
        if s.mode == .alwaysAwake, !onAC, let p = batteryPercent, p <= Self.lowBatteryPercent {
            stop(.lowBattery(p))
        }
    }

    /// Run once at launch. A `disablesleep` this app set in an earlier life — a crash, a kill, a power loss —
    /// belongs to a session that no longer exists, so it is cleared. One someone set by hand is not touched.
    public func reconcileAtLaunch() {
        guard weSetSleepDisabled else { return }
        if lid.sleepDisabled() == false {
            defaults.set(false, forKey: Self.weSetItKey)   // already back to normal
        } else {
            _ = restoreSleep()
        }
    }

    /// Seconds left in the session, or nil if it has no end (or there is none).
    public func remaining() -> TimeInterval? {
        guard let end = session?.endsAt else { return nil }
        return max(0, end.timeIntervalSince(now()))
    }

    private func restoreSleep() -> Bool {
        if lid.setSleepDisabled(false) {
            defaults.set(false, forKey: Self.weSetItKey)
            return true
        }
        return false
    }
}

// ── The real machine ────────────────────────────────────────────────────────

public final class IOKitSleepAssertions: SleepAssertions {
    private var display = IOPMAssertionID(kIOPMNullAssertionID)
    private var system = IOPMAssertionID(kIOPMNullAssertionID)

    public init() {}
    deinit { release() }

    public func hold(reason: String) -> Bool {
        release()
        let d = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &display)
        let s = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &system)
        if d != kIOReturnSuccess || s != kIOReturnSuccess { release(); return false }
        return true
    }

    public func release() {
        if display != IOPMAssertionID(kIOPMNullAssertionID) { IOPMAssertionRelease(display) }
        if system != IOPMAssertionID(kIOPMNullAssertionID) { IOPMAssertionRelease(system) }
        display = IOPMAssertionID(kIOPMNullAssertionID)
        system = IOPMAssertionID(kIOPMNullAssertionID)
    }
}

/// `pmset -a disablesleep`, run through the narrow sudoers rule `KeepAwakeAuthorisation` installs.
public final class PmsetClosedLidSleep: ClosedLidSleepControl {
    public init() {}

    public func sleepDisabled() -> Bool? {
        guard let out = Self.run("/usr/bin/pmset", ["-g"]) else { return nil }
        return Self.parseSleepDisabled(out.output)
    }

    /// The value on the `SleepDisabled` line of `pmset -g`, nil if there is no such line.
    static func parseSleepDisabled(_ text: String) -> Bool? {
        for line in text.split(separator: "\n") {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if words.count >= 2, words[0] == "SleepDisabled" { return words[1] != "0" }
        }
        return nil
    }

    public func setSleepDisabled(_ on: Bool) -> Bool {
        // -n: never prompt. Without the rule this fails at once instead of waiting on a password nobody sees.
        guard let r = Self.run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"]),
              r.status == 0 else { return false }
        return sleepDisabled() == on
    }

    public func isAuthorised() -> Bool {
        Self.run("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "1"])?.status == 0
            && Self.run("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "0"])?.status == 0
    }

    static func run(_ path: String, _ args: [String]) -> (status: Int32, output: String)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

// ── The permission ──────────────────────────────────────────────────────────

/// Installing and removing the one sudoers rule Always Stay Awake needs.
///
/// The rule names this user and two exact command lines. sudo matches arguments literally when a rule gives
/// them, so `pmset -a disablesleep 1` and `... 0` are allowed and `pmset -a disablesleep 1; anything` or
/// `pmset -a sleep 0` are not. The installer script is built entirely from constants and a validated user name,
/// and writes the rule from INSIDE the privileged shell: a file prepared by the app first, then installed, would
/// leave the user-writable file open to being swapped while the password prompt is on screen.
public enum KeepAwakeAuthorisation {

    public static let path = "/etc/sudoers.d/anode-keep-awake"

    public static func rule(user: String) -> String {
        "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0"
    }

    /// Short account names: letters, digits, dot, dash, underscore. Anything else is refused rather than escaped.
    static func isSafe(user: String) -> Bool {
        !user.isEmpty && user.count <= 64 && user.first != "-"
            && user.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    /// The shell script root runs, or nil for a user name that cannot go in a sudoers file safely. No double quotes
    /// anywhere in it: it travels inside an AppleScript string.
    public static func installScript(user: String) -> String? {
        guard isSafe(user: user) else { return nil }
        return "umask 077; /bin/mkdir -p /etc/sudoers.d; t=$(/usr/bin/mktemp /tmp/anode-sudoers.XXXXXX) || exit 1; "
             + "printf '%s\\n' '\(rule(user: user))' > $t; "
             + "/usr/sbin/visudo -cf $t >/dev/null && /usr/bin/install -m 0440 -o root -g wheel $t \(path); r=$?; "
             + "/bin/rm -f $t; exit $r"
    }

    public static let removeScript = "/bin/rm -f \(path)"

    static func appleScript(running shell: String, prompt: String) -> String {
        "do shell script \"\(shell.replacingOccurrences(of: "\\", with: "\\\\"))\" "
            + "with prompt \"\(prompt)\" with administrator privileges"
    }

    /// Ask for admin rights once and install the rule. `completion` runs on the main queue.
    public static func install(user: String = NSUserName(), completion: @escaping (Bool) -> Void) {
        guard let shell = installScript(user: user) else { DispatchQueue.main.async { completion(false) }; return }
        runAsAdmin(shell,
                   prompt: "Anode wants to let Always Stay Awake keep your Mac running with the lid closed.",
                   completion: completion)
    }

    public static func remove(completion: @escaping (Bool) -> Void) {
        runAsAdmin(removeScript, prompt: "Anode wants to remove the Always Stay Awake permission.",
                   completion: completion)
    }

    private static func runAsAdmin(_ shell: String, prompt: String, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = PmsetClosedLidSleep.run("/usr/bin/osascript",
                                             ["-e", appleScript(running: shell, prompt: prompt)])?.status == 0
            DispatchQueue.main.async { completion(ok) }
        }
    }
}
