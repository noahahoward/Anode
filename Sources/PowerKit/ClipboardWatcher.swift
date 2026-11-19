import Foundation

// ── Watching the pasteboard ─────────────────────────────────────────────────
//
// The pasteboard says nothing when it changes; the only way to notice is to ask for its change counter now and then. Asking
// for the counter reads no contents (and so asks nothing of the person), and the contents are read only when it has moved
// and the copy passes the rules in `ClipboardPrivacy`, judged from the type strings and the app in front before any data is.
//
// Everything that touches the Mac is a closure, so this is tested with a fake pasteboard.

public final class ClipboardWatcher {

    public enum PollResult: Equatable {
        case unchanged
        /// The change was Anode's own (an entry put back on the pasteboard to be pasted).
        case ownWrite
        case skipped(String)
        case recorded(ClipboardStore.AddResult)
    }

    private let changeCount: () -> Int
    private let types: () -> [String]
    private let read: (_ maxBytes: Int) -> [ClipboardRepresentation]?
    private let frontApp: () -> (bundleID: String?, name: String?)
    private let store: ClipboardStore
    private let policy: () -> ClipboardStore.Policy
    private let log: (String) -> Void
    private var lastCount: Int
    private var ownCount: Int?

    /// - Parameters:
    ///   - changeCount: the pasteboard's change counter. Reading it reads nothing of the contents.
    ///   - types: the type strings now on the pasteboard.
    ///   - read: every form of every item, or nil if it cannot be read or is over the given size.
    ///   - frontApp: the app in front, which is taken to be the one that copied.
    public init(changeCount: @escaping () -> Int, types: @escaping () -> [String],
                read: @escaping (_ maxBytes: Int) -> [ClipboardRepresentation]?,
                frontApp: @escaping () -> (bundleID: String?, name: String?), store: ClipboardStore,
                policy: @escaping () -> ClipboardStore.Policy, log: @escaping (String) -> Void) {
        self.changeCount = changeCount
        self.types = types
        self.read = read
        self.frontApp = frontApp
        self.store = store
        self.policy = policy
        self.log = log
        self.lastCount = changeCount()
    }

    /// Take the pasteboard as it is now as already seen. Called when watching starts, and when it starts again after a pause
    /// or a sleep: what was copied while nobody was watching is never recorded.
    public func resync() {
        lastCount = changeCount()
        ownCount = nil
    }

    /// The pasteboard's counter after Anode itself wrote to it: that change is not a copy to record.
    public func noteOwnWrite(changeCount count: Int) {
        ownCount = count
    }

    @discardableResult
    public func poll(now: Date = Date()) -> PollResult {
        let count = changeCount()
        guard count != lastCount else { return .unchanged }
        lastCount = count
        if count == ownCount { return .ownWrite }

        let front = frontApp()
        let present = types()
        let rules = policy()
        if let why = ClipboardPrivacy.skipReason(types: present, sourceBundleID: front.bundleID, ignoredApps: rules.ignoredApps) {
            // The kind of thing and who made it: never what it said.
            log("not recorded (\(why)) from \(front.bundleID ?? "an unknown app")")
            return .skipped(why)
        }
        guard let reps = read(store.limits.maxEntryBytes) else {
            log("not recorded (too large or unreadable) from \(front.bundleID ?? "an unknown app")")
            return .skipped("too large or unreadable")
        }
        let snapshot = ClipboardSnapshot(representations: reps, sourceBundleID: front.bundleID, sourceName: front.name, date: now)
        let result = store.add(snapshot, policy: rules)
        if case .skipped(let why) = result { log("not recorded (\(why)) from \(front.bundleID ?? "an unknown app")") }
        return .recorded(result)
    }
}
