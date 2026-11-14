import Foundation
import PowerKit

// ── Where Charge Control keeps the record of macOS's own settings ───────────
//
// One record for the whole Mac (`ChargeRecordStore`, a file every account can write), so that two accounts' Anodes
// cannot take each other's limit for macOS's own. This is the controller's one way to the record: it asks to
// `acquire` it when switching on, to `release` it when putting back, and a few questions about what is there.
//
// If the shared file cannot be had (`/Users/Shared` missing or read-only, or a file another account made that this one
// cannot write) it falls back to this account's own record in its preferences (`Settings.chargeRestoreRecord`), with
// the rules that had before the record was shared, and logs one line saying two accounts cannot be told apart on
// this Mac. The tests use that mode (no store) unless they are about two accounts.
//
// A per-account record left by an earlier build is moved into the shared file, with this account as a holder whose
// process is not known, so that the launch that finds it lifts the limit as for any run that did not quit. After that
// nothing reads the per-account key. `chargeCutUnconfirmed` and `chargeStartPending` stay per account: they are about
// this account's own discharge and start.

/// What `acquire` found.
enum RecordAcquired: Equatable {
    /// The shared record could not be reached (another Anode holds its lock for longer than this one waits): nothing
    /// was written and nothing was changed.
    case unreachable
    /// No record was there: macOS was read, and what it said is written down as macOS's own.
    case recorded(NativeChargeState)
    /// A record was there, so macOS's settings now are somebody's limit and are not written down; this account is a
    /// holder of the record that stands. `readable` is false for a per-account record that cannot be read.
    case adopted(readable: Bool)
    /// No record, and macOS would not say what its settings are.
    case macOSUnreadable
}

/// What there is to put back.
enum RecordOriginal {
    case state(NativeChargeState)
    /// A per-account record that is there and cannot be read: macOS's defaults are put back instead.
    case unreadableText
    /// No record: it was lost while Charge Control was on.
    case none
}

/// What `release` did.
enum RecordReleased: Equatable {
    /// The shared record could not be reached: nothing was put back, and this account is left a stale holder, so the
    /// next launch of any account's Anode lifts the limit.
    case unreachable
    /// This account was the last holder: the closure ran, and said whether everything was put back (true clears the
    /// record; false keeps it for the next launch of any account's Anode to lift).
    case restored(Bool)
    /// Another account's Anode is running and holds the limit: nothing was put back.
    case handedOver
    /// The shared file is there and is not a record: nothing is put back from it.
    case unreadable(String)
}

final class ChargeRecords {

    private enum Mode { case shared, perAccount }

    private let settings: Settings
    private let store: ChargeRecordStore?
    private let log: (String) -> Void
    /// Decided the first time something is written (or the file proves unusable), and kept.
    private var mode: Mode?
    private var saidUnreadable = false

    /// `store` nil: this account's own record only.
    init(settings: Settings, store: ChargeRecordStore? = nil, log: @escaping (String) -> Void = { _ in }) {
        self.settings = settings
        self.store = store
        self.log = log
    }

    /// The real one: the file in `/Users/Shared/Anode`, logging to the charge log.
    static func live(settings: Settings = .shared) -> ChargeRecords {
        ChargeRecords(settings: settings, store: ChargeRecordStore(), log: { FeatureLog.append("charge.log", $0) })
    }

    // ── Questions (nothing is created, nothing is written) ──────────────────

    /// This account's own record: the fallback's, or one an earlier build left that is yet to be moved.
    private var perAccountText: String? { settings.chargeRestoreRecord }

    /// The shared record, as it stands. Not consulted when the shared file proved unusable. A file that is there and is
    /// not a record counts as no record, and is said once.
    private func sharedRecord() -> SharedChargeRecord? {
        guard let store, mode != .perAccount else { return nil }
        switch store.peek() {
        case .record(let r)?: return r
        case .unreadable(let why)?:
            sayUnreadable(why)
            return nil
        case .none?, nil: return nil
        }
    }

    private func sayUnreadable(_ why: String) {
        guard !saidUnreadable else { return }
        saidUnreadable = true
        log("the shared record of macOS's own settings is not a record (\(why)); it is taken for none, and nothing is "
            + "put back from it")
    }

    /// Anything recorded that quitting or switching off has to deal with. A shared file that cannot be read at the
    /// moment (its lock is held, say) may hold one: it is taken for one, so that the release is attempted and says
    /// what happened.
    var hasRecord: Bool {
        if perAccountText != nil { return true }
        guard let store, mode != .perAccount else { return false }
        switch store.peek() {
        case .record?: return true
        case .unreadable(let why)?:
            sayUnreadable(why)
            return false
        case .none?: return false
        case nil: return true
        }
    }

    /// The last run of this account did not release: a record says it held the limit under another process, or says
    /// nobody alive holds it, or an earlier build left this account's own. Not when another account's live Anode
    /// holds it. With the per-account record, as before: it is there.
    func lastRunDidNotRelease() -> Bool {
        if perAccountText != nil { return true }
        guard let store, let r = sharedRecord() else { return false }
        return store.looksUnclean(r)
    }

    /// Whether the record names process `pid` of this account as a holder: that process took the limit and has not
    /// given it back. nil when the shared record cannot be read at the moment (its lock is held). With this account's
    /// own record there are no holders to read: a record that is there is taken for that process's.
    func isHeld(byProcess pid: Int32) -> Bool? {
        if perAccountText != nil { return true }
        guard let store, mode != .perAccount else { return false }
        switch store.peek() {
        case .record(let r)?: return r.holders.contains(ChargeHolder(uid: store.me.uid, pid: pid))
        case .unreadable(let why)?:
            sayUnreadable(why)
            return false
        case .none?: return false
        case nil: return nil
        }
    }

    /// While off: a record this account has to put back, because nobody else is holding it. (One another account's
    /// live Anode holds is that Anode's to put back.)
    func leftOverForThisAccount() -> Bool {
        if perAccountText != nil { return true }
        guard let store, let r = sharedRecord() else { return false }
        return store.liveOthers(r).isEmpty
    }

    /// A record stands and another account's live Anode holds it.
    var heldByAnotherAccount: Bool {
        guard let store, let r = sharedRecord() else { return false }
        return !store.liveOthers(r).isEmpty
    }

    /// The original settings the record holds, for display and tests. nil for none or one that cannot be read.
    var original: NativeChargeState? {
        if let text = perAccountText { return ChargeController.decodeRecord(text) }
        return sharedRecord()?.original
    }

    // ── Which record ────────────────────────────────────────────────────────

    /// The record is the Mac's, shared by every account's Anode, so who holds the limit is known. False when it is this
    /// account's own (no shared file here, or it could not be had): two accounts cannot be told apart then.
    var isShared: Bool { resolved() != nil }

    /// The store when records are shared on this Mac; nil when they are per account. The first time, the file is
    /// made if need be and a record an earlier build left in this account's preferences is moved into it. Only a
    /// folder or file that cannot be had at all makes the record per account, and for good: a file that is merely
    /// busy at some moment does not (`acquire` and `release` say `unreachable`).
    private func resolved() -> ChargeRecordStore? {
        if let mode { return mode == .shared ? store : nil }
        guard let store else {
            mode = .perAccount
            return nil
        }
        if let why = store.checkUsable() {
            fallBack(why)
            return nil
        }
        mode = .shared
        if let text = perAccountText {
            let original = ChargeController.decodeRecord(text) ?? ChargeController.defaultRecord
            if store.adopt(legacy: original) {
                settings.chargeRestoreRecord = nil
                settings.flush()
                log("moved this account's record of macOS's own settings into the shared one")
            }
        }
        return store
    }

    private func fallBack(_ why: String) {
        mode = .perAccount
        log("macOS's own charge settings are recorded in this account's preferences, not shared: \(why), so two "
            + "accounts cannot be told apart on this Mac")
    }

    // ── Switching on and putting back ───────────────────────────────────────

    /// Switching on. A record that is there stands (macOS's settings now are somebody's limit): this account is added
    /// to its holders. With none, `read` asks macOS and what it says is written down, with this account the only
    /// holder, before anything is changed.
    func acquire(read: () -> NativeChargeState?) -> RecordAcquired {
        if let store = resolved() {
            if case .unreadable(let why)? = store.peek() { sayUnreadable(why) }
            switch store.acquire(readMacOS: read) {
            case .recorded(let found)?: return .recorded(found)
            case .adopted?: return .adopted(readable: true)
            case .macOSUnreadable?: return .macOSUnreadable
            case nil:
                // Busy, or not writable just now: not a reason to record into this account's preferences, where it
                // could be another account's limit. Nothing is changed this time.
                return .unreachable
            }
        }
        if let text = perAccountText { return .adopted(readable: ChargeController.decodeRecord(text) != nil) }
        guard let found = read(), let json = ChargeController.encodeRecord(found) else { return .macOSUnreadable }
        settings.chargeRestoreRecord = json
        settings.flush()
        return .recorded(found)
    }

    /// Putting back. This account stops being a holder; if no other live Anode holds the record, `restore` is called
    /// with what to put back and says whether all of it was; a restore that worked clears the record, one that did not
    /// keeps it, with nobody holding it. If another account's live Anode holds it, nothing is put back.
    func release(restore: (RecordOriginal) -> Bool) -> RecordReleased {
        if let store = resolved() {
            switch store.release(restore: { restore($0.map { .state($0) } ?? .none) }) {
            case .restored(let ok)?: return .restored(ok)
            case .handedOver?: return .handedOver
            case .unreadable(let why)?:
                sayUnreadable(why)
                return .unreadable(why)
            case nil:
                // Busy: nothing is put back, and above all not macOS's defaults over a limit the record says is
                // another account's.
                return .unreachable
            }
        }
        let original: RecordOriginal
        if let text = perAccountText {
            original = ChargeController.decodeRecord(text).map { .state($0) } ?? .unreadableText
        } else {
            original = .none
        }
        let ok = restore(original)
        if ok {
            settings.chargeRestoreRecord = nil
            settings.flush()
        }
        return .restored(ok)
    }
}
