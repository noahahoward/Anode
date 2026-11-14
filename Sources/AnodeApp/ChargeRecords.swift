import Foundation
import PowerKit

// ── Where Charge Control keeps the record of macOS's own settings ───────────
//
// One record for the whole Mac (`ChargeRecordStore`, a file every account can write), so that two accounts' Anodes
// cannot take each other's limit for macOS's own. This is the controller's one way to the record: it asks to
// `acquire` it when switching on, to `release` it when putting back, and a few questions about what is there.
//
// If the shared file cannot be had (`/Users/Shared` missing or read-only, or something at the path that this account
// cannot use) nothing is recorded, and so nothing is changed: Charge Control holds no limit on this Mac while that is
// so, and says why (`RecordAcquired.unusable`). Up to 1.18.1 it kept this account's own record in its preferences
// instead, and two accounts doing that could not be told apart: the second wrote the first's limit down as macOS's
// own and put it back on quitting, and the limit stayed with no Anode running. A record of macOS's settings that is
// not shared is one nobody can trust, so there is none. The folder is looked at again each time Charge Control is
// switched on.
//
// A per-account record left by an earlier build (`Settings.chargeRestoreRecord`) is moved into the shared file, with
// this account as a holder whose process is not known, so that the launch that finds it lifts the limit as for any
// run that did not quit; where the shared file cannot be had it is put back from where it is, and nothing new is
// written there. `chargeCutUnconfirmed` and `chargeStartPending` stay per account: they are about this account's own
// discharge and start.
//
// A `ChargeRecords` made with no store keeps this account's own record only, with the rules from before the record
// was shared. The app never makes one; the tests do, unless they are about two accounts.

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
    /// The shared record cannot be kept on this Mac (the sentence says why): nothing was written and nothing may be
    /// changed, because a record no other account's Anode can read would be taken for macOS's own by theirs.
    case unusable(String)
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

    private enum Mode: Equatable {
        case shared
        /// No store was given: this account's own record (the tests).
        case perAccount
        /// A store was given and its file cannot be had; why.
        case unusable(String)
    }

    private let settings: Settings
    private let store: ChargeRecordStore?
    private let log: (String) -> Void
    /// Decided the first time something is written (or the file proves unusable), and kept.
    private var mode: Mode?
    private var saidUnreadable = false
    private var saidUnusable: String?

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

    /// This account's own record: one an earlier build left that is yet to be moved or put back (or, with no store,
    /// the only record there is).
    private var perAccountText: String? { settings.chargeRestoreRecord }

    /// The store, unless it is known that there is none to use: none was given, or its file cannot be had.
    private var storeInUse: ChargeRecordStore? {
        switch mode {
        case .perAccount?, .unusable?: return nil
        case .shared?, nil: return store
        }
    }

    /// The shared record, as it stands. Not consulted when the shared file proved unusable. A file that is there and is
    /// not a record counts as no record, and is said once.
    private func sharedRecord() -> SharedChargeRecord? {
        guard let store = storeInUse else { return nil }
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
        guard let store = storeInUse else { return false }
        switch store.peek() {
        case .record?: return true
        case .unreadable(let why)?:
            sayUnreadable(why)
            return false
        case .none?: return false
        // Busy is "may hold one", and so is a file this Anode has written to that has since become something the
        // store refuses: the record in it is lost, and the release deals with that. A file that could never be had
        // holds nothing of this Anode's.
        case nil: return mode == .shared || store.isUsable()
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
        guard let store = storeInUse else { return false }
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
    /// account's own (no store), or the shared file cannot be had.
    var isShared: Bool { resolved() != nil }

    /// Why the shared record cannot be kept on this Mac, when that is so.
    var unusableBecause: String? {
        if case .unusable(let why)? = mode { return why }
        return nil
    }

    /// The store when records are shared on this Mac; nil when there is no store, or its file cannot be had. The first
    /// time, the file is made if need be and a record an earlier build left in this account's preferences is moved
    /// into it. A folder or file that cannot be had is looked at again every time (it may have been put right since);
    /// one that is merely busy at some moment is not "cannot be had" (`acquire` and `release` say `unreachable`).
    private func resolved() -> ChargeRecordStore? {
        switch mode {
        case .shared?: return store
        case .perAccount?: return nil
        case .unusable?, nil: break
        }
        guard let store else {
            mode = .perAccount
            return nil
        }
        if let why = store.checkUsable() {
            noteUnusable(why)
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

    private func noteUnusable(_ why: String) {
        mode = .unusable(why)
        guard saidUnusable != why else { return }
        saidUnusable = why
        log("macOS's own charge settings cannot be recorded where every account's Anode reads them: \(why). Charge "
            + "Control holds no limit on this Mac while that is so")
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
        // Nothing is written anywhere when the shared file cannot be had: this account's own preferences are not a
        // place another account's Anode can read.
        if let why = unusableBecause { return .unusable(why) }
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
                // Not busy but gone (the file was replaced by something this store refuses while the limit was held):
                // the record is lost, as when it is removed by hand, and Charge Control's limit is not left in force
                // for that. `restore` puts back macOS's defaults.
                if let why = store.checkUsable() {
                    noteUnusable(why)
                    return .restored(restore(RecordOriginal.none))
                }
                // Busy: nothing is put back, and above all not macOS's defaults over a limit the record says is
                // another account's.
                return .unreachable
            }
        }
        // The shared file cannot be had and this account left nothing of its own: nothing was ever recorded here.
        if unusableBecause != nil, perAccountText == nil { return .restored(true) }
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
