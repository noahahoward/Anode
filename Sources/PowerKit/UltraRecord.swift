import Foundation

/// What Ultra Low Power Mode has done to the Mac, written down as it is done.
///
/// The record is how a session is undone when Anode did not get to end it: the watchdog and the next launch read it
/// and put back what it names, and nothing else. A process is named by its pid AND its start time, so a pid that was
/// recycled since is never continued. The record is a plain value; where it is kept is `UltraRecordStoring`.
public struct UltraRecord: Codable, Equatable {

    /// Every group frozen this session, released or not. A released group stays listed so the record is a full account
    /// of the session, but recovery leaves it alone: it was continued already.
    public var groups: [Group]

    public struct Group: Codable, Equatable {
        public var id: String
        public var name: String
        public var members: [Member]
        /// The app that was hidden before it was stopped; nil when nothing was hidden.
        public var appPID: Int32?
        public var released: Bool

        public init(id: String, name: String, members: [Member], appPID: Int32? = nil, released: Bool = false) {
            self.id = id
            self.name = name
            self.members = members
            self.appPID = appPID
            self.released = released
        }
    }

    public struct Member: Codable, Equatable {
        public var pid: Int32
        public var startTime: UInt64

        public init(pid: Int32, startTime: UInt64) {
            self.pid = pid
            self.startTime = startTime
        }
    }

    /// The screen's brightness before the mode lowered it; nil when the mode did not lower it.
    public var brightnessBefore: Float?
    /// The mode asked for a lower refresh rate, so ending it has to ask for the earlier one back.
    public var rateLowered: Bool
    /// The keyboard backlight before the mode switched it off; nil when the mode did not.
    public var keyboardBefore: Float?
    /// macOS's power mode before the mode changed it; nil when this feature did not change it.
    public var powerModeBefore: Int?
    /// Whether Low Power Mode was already on, as macOS reports it, when the session asked the helper to switch it on. True means it
    /// was the owner's own and stays on, so ending the session has no Low Power Mode to wait for. Optional so that a record written by
    /// a build that did not name it still loads (as nil, which is not known to be the owner's own).
    public var lowPowerBefore: Bool?
    /// Every process the mode put under the background policy, named before the policy was applied. Optional so that a record
    /// written by a build that had no such part still loads (as nil, which lifts nothing).
    public var throttled: [Member]?

    /// Nothing frozen, nothing changed.
    public init() {
        groups = []
        brightnessBefore = nil
        rateLowered = false
        keyboardBefore = nil
        powerModeBefore = nil
        lowPowerBefore = nil
        throttled = nil
    }

    /// Whether putting the screen back has to wait for Low Power Mode to be off. macOS raises the screen when Low Power Mode ends,
    /// by an amount that depends on the level (measured: 0.12 became 0.1516, 0.80 became 0.9225), so a level set before that is
    /// lost and the screen has to be put back after it. That is so when there is a screen to put back and the session asked the helper
    /// for Low Power Mode and it was not the owner's own: `lowPowerBefore` is written before the helper is asked, so `false` means
    /// exactly that, whether or not the helper's answer reached the record (a cancel, a quit or a crash during the helper step leaves
    /// Low Power Mode possibly on and `powerModeBefore` empty). Where it never went on, the wait is only the settle.
    public var waitsForLowPowerToEnd: Bool {
        brightnessBefore != nil && lowPowerBefore == false
    }

    /// Whether nothing is left in this record for a launch to do once the watchdog has undone what it can. The watchdog continues
    /// every process the record names, lifts every limit it names, puts the screen back, and leaves the power mode to the helper (which
    /// puts it back itself when Anode's connection closes). It does not unhide an app (one it hid and the owner has not brought back),
    /// put the refresh rate back or write the keyboard light: those wait for a launch, and a record that names one is kept.
    public var leavesNothingForALaunch: Bool {
        !rateLowered && keyboardBefore == nil && !groups.contains { !$0.released && $0.appPID != nil }
    }
}

/// Where the record is kept. A protocol so that tests, and the controller's tests, use a fake and never the real file.
public protocol UltraRecordStoring: AnyObject {
    /// nil when there is no record, or what is there cannot be read.
    func load() -> UltraRecord?
    /// False when the record did not reach the disk; true only after it has been written. The caller must not freeze
    /// anything on a false: stopped processes with no record are stopped for good if Anode dies.
    @discardableResult
    func save(_ record: UltraRecord) -> Bool
    func clear()
}

/// The record in one small file.
///
/// A save writes a new file and moves it into place, so a crash in the middle of a save leaves the old record whole,
/// never half of a new one. Anything unreadable (missing, empty, cut short, not a record) loads as no record: the
/// caller then has nothing to undo, which is all it can know.
public final class UltraRecordFile: UltraRecordStoring {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> UltraRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(UltraRecord.self, from: data)
    }

    @discardableResult
    public func save(_ record: UltraRecord) -> Bool {
        do {
            let data = try JSONEncoder().encode(record)
            // The folder may not exist yet on the first freeze.
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            // A record that cannot be written is a freeze nobody can undo, so the caller is told. What was on the disk
            // before is left as it was: the write is atomic.
            return false
        }
    }

    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// What undoes a session Anode did not end.
public enum UltraRecovery {
    public enum Action: Equatable {
        case resume(pid: Int32, startTime: UInt64)
        /// Lifts the background policy from a process the mode put it on.
        case unthrottle(pid: Int32, startTime: UInt64)
        case unhide(pid: Int32)
        case brightness(Float)
        case restoreRate
        case keyboard(Float)
        case powerMode(Int)
    }

    /// What undoes `record`, in order: processes first.
    ///
    /// Only what the record names is continued, and only the groups not released already. Every process is continued
    /// before the background policy is lifted from every process the record names (released groups included: a group that
    /// came back is the one that was put under it), and both before any app is asked to unhide (a stopped app cannot answer,
    /// and a call into another app can stall), and all of that before any setting. `brightnessNow` is the screen's
    /// brightness as read now, nil when it cannot be read; the brightness is named by `BrightnessCeiling.restore`.
    ///
    /// The list is the order of the undo, with one exception the callers apply: the brightness step is done by them LAST, after
    /// the power mode and after Low Power Mode is off (`UltraRecord.waitsForLowPowerToEnd`), and not where it stands in the list,
    /// because macOS raises the screen when Low Power Mode ends.
    public static func actions(for record: UltraRecord, brightnessNow: Float?) -> [Action] {
        let open = record.groups.filter { !$0.released }
        var actions: [Action] = open.flatMap { group in
            group.members.map { Action.resume(pid: $0.pid, startTime: $0.startTime) }
        }
        actions += (record.throttled ?? []).map { Action.unthrottle(pid: $0.pid, startTime: $0.startTime) }
        actions += open.compactMap { group in group.appPID.map { Action.unhide(pid: $0) } }

        if let brightness = BrightnessCeiling.restore(before: record.brightnessBefore, now: brightnessNow) {
            actions.append(.brightness(brightness))
        }
        if record.rateLowered { actions.append(.restoreRate) }
        if let keyboard = record.keyboardBefore { actions.append(.keyboard(keyboard)) }
        if let mode = record.powerModeBefore { actions.append(.powerMode(mode)) }
        return actions
    }
}
