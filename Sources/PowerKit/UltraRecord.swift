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

    /// Nothing frozen, nothing changed.
    public init() {
        groups = []
        brightnessBefore = nil
        rateLowered = false
        keyboardBefore = nil
        powerModeBefore = nil
    }
}

/// Where the record is kept. A protocol so that tests, and the controller's tests, use a fake and never the real file.
public protocol UltraRecordStoring: AnyObject {
    /// nil when there is no record, or what is there cannot be read.
    func load() -> UltraRecord?
    func save(_ record: UltraRecord)
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

    public func save(_ record: UltraRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        // The folder may not exist yet on the first freeze; a record that cannot be written is a freeze nobody can undo.
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// What undoes a session Anode did not end.
public enum UltraRecovery {
    public enum Action: Equatable {
        case resume(pid: Int32, startTime: UInt64)
        case unhide(pid: Int32)
        case brightness(Float)
        case restoreRate
        case keyboard(Float)
        case powerMode(Int)
    }

    /// What undoes `record`, in order: processes first.
    ///
    /// Only what the record names is continued, and only the groups not released already. Every process is continued
    /// before any app is asked to unhide (a stopped app cannot answer, and a call into another app can stall), and all
    /// of that before any setting. `brightnessNow` is the screen's brightness as read now, nil when it cannot be read.
    public static func actions(for record: UltraRecord, brightnessNow: Float?) -> [Action] {
        let open = record.groups.filter { !$0.released }
        var actions: [Action] = open.flatMap { group in
            group.members.map { Action.resume(pid: $0.pid, startTime: $0.startTime) }
        }
        actions += open.compactMap { group in group.appPID.map { Action.unhide(pid: $0) } }

        if let brightness = restoredBrightness(before: record.brightnessBefore, now: brightnessNow) {
            actions.append(.brightness(brightness))
        }
        if record.rateLowered { actions.append(.restoreRate) }
        if let keyboard = record.keyboardBefore { actions.append(.keyboard(keyboard)) }
        if let mode = record.powerModeBefore { actions.append(.powerMode(mode)) }
        return actions
    }

    /// The earlier brightness comes back only when the mode lowered it and the screen is still where the mode left it
    /// (at the ceiling, give or take what the display reports). Dimmer than that is the owner's choice, and unreadable
    /// leaves no way to tell.
    private static func restoredBrightness(before: Float?, now: Float?) -> Float? {
        guard let before, let now, abs(now - 0.5) <= 0.01 else { return nil }
        return before
    }
}
