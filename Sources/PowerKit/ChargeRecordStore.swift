import Foundation
import Darwin

// ── The record of macOS's own charge settings, one for the whole Mac ────────
//
// macOS's charge limit is one setting for the whole Mac, but every account that uses Anode has its own Anode and its
// own preferences. A record of "macOS's own settings" kept per account goes wrong with two accounts: the second
// account's Anode starts while the first holds a limit, writes the first's limit down as macOS's own, and on quitting
// puts it back; the first one, not on screen, puts nothing back; and macOS is left at a limit with no Anode running.
//
// So there is one record, in one small file every account can read and write, and a list of who is holding the
// limit. Switching on adopts a record that is already there (macOS's settings are then somebody's limit, not macOS's
// own) and adds this Anode to the holders. Putting back removes this Anode from the holders, and only the last live
// holder puts anything back.
//
// The file is `/Users/Shared/Anode/charge-control.json`, folder and file open to everyone. The folder is sticky, so
// one account cannot delete or rename another's file; it is written in place, under an exclusive `flock`, never
// replaced. An empty file is "no record". Anything read from it is validated: it is writable by any local user, which
// grants nothing new (any user can set the limit through the system's own client), but a bad value must not become a
// limit written to macOS or a process signalled.
//
// Format (version 1):
//
//     {"version":1,
//      "original":{"mclEnabled":true,"mclLimit":90,"optimizedChargingEnabled":true},
//      "holders":[{"uid":501,"pid":1234}]}
//
// A holder is live when its pid is a running process whose executable is Anode's app binary
// (`ChargeHolderLiveness`); a dead pid, or one that now belongs to something else, is stale and dropped whenever the
// file is next written. A holder with pid 0 is one whose process is not known (a per-account record moved here from
// an earlier build): always stale.

/// One Anode that holds macOS's charge limit.
public struct ChargeHolder: Equatable, Hashable, Codable {
    public var uid: UInt32
    public var pid: Int32

    public init(uid: UInt32, pid: Int32) {
        self.uid = uid
        self.pid = pid
    }
}

/// What macOS's charge settings were before any Anode changed them, and who has them changed.
public struct SharedChargeRecord: Equatable {
    public var original: NativeChargeState
    public var holders: [ChargeHolder]

    public init(original: NativeChargeState, holders: [ChargeHolder]) {
        self.original = original
        self.holders = holders
    }
}

/// Whether a pid is a running Anode, for any account, with no privilege.
///
/// Measured on macOS 27.0 (Mac17,9) as an ordinary user: `proc_pidpath` returns the executable's path for processes
/// of other users (root's launchd and logd, `_windowserver`'s WindowServer, `_corespeechd`'s corespeechd) and fails
/// with ESRCH for a pid that does not exist, while `kill(pid, 0)` says EPERM for another user's process, which is
/// "alive" but nothing more. So the path is the evidence: it says the process exists and what it is. A pid reused by
/// something else has another path and is not Anode.
public enum ChargeHolderLiveness {

    /// The tail of the path of Anode's executable inside its bundle, wherever the bundle is installed.
    public static let binarySuffix = "/Contents/MacOS/AnodeApp"

    public static func isAnodeBinary(path: String) -> Bool { path.hasSuffix(binarySuffix) }

    public static func executablePath(of pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4 * 1024)
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return n > 0 ? String(cString: buffer) : nil
    }

    public static func isLiveAnode(pid: Int32) -> Bool {
        guard let path = executablePath(of: pid) else { return false }
        return isAnodeBinary(path: path)
    }
}

public final class ChargeRecordStore {

    public static let sharedDirectory = "/Users/Shared/Anode"
    public static let fileName = "charge-control.json"
    /// A record is a few hundred bytes. Anything bigger is not one.
    public static let maxBytes = 16 * 1024
    static let maxHolders = 64
    static let limitRange = 20...100

    /// This Anode, as a holder.
    public let me: ChargeHolder
    private let directory: String
    private let isLiveProcess: (Int32) -> Bool
    private let lockTimeout: TimeInterval

    /// `directory` is a parameter so the tests use a temporary folder: no test may touch `/Users/Shared`.
    public init(directory: String = ChargeRecordStore.sharedDirectory, uid: UInt32 = getuid(), pid: Int32 = getpid(),
                isLive: @escaping (Int32) -> Bool = ChargeHolderLiveness.isLiveAnode, lockTimeout: TimeInterval = 3) {
        self.directory = directory
        self.me = ChargeHolder(uid: uid, pid: pid)
        self.isLiveProcess = isLive
        self.lockTimeout = lockTimeout
    }

    public var path: String { directory + "/" + Self.fileName }

    public func isLive(_ holder: ChargeHolder) -> Bool { holder.pid > 0 && isLiveProcess(holder.pid) }

    /// Holders other than this account that are running now.
    public func liveOthers(_ record: SharedChargeRecord) -> [ChargeHolder] {
        record.holders.filter { $0.uid != me.uid && isLive($0) }
    }

    /// The last run of this account did not release: the record lists it as a holder under another process (that run
    /// died holding the limit, or this is a second copy), or lists nobody alive at all (an Anode died holding it, or a
    /// restore was refused). Not when another account's live Anode holds it: that one is not dead.
    public func looksUnclean(_ record: SharedChargeRecord) -> Bool {
        record.holders.contains { $0.uid == me.uid && $0.pid != me.pid }
            || !record.holders.contains { isLive($0) }
    }

    // ── What the file says ──────────────────────────────────────────────────

    public enum Contents: Equatable {
        /// Missing or empty: no record.
        case none
        case record(SharedChargeRecord)
        /// There is something, and it is not a record; the sentence says what.
        case unreadable(String)
    }

    /// The file's text as a record, validated. Pure.
    public static func parse(_ data: Data) -> Contents {
        if data.isEmpty { return .none }
        guard data.count <= maxBytes else { return .unreadable("larger than a record can be") }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unreadable("not JSON")
        }
        guard (object["version"] as? Int) == 1 else { return .unreadable("a version this Anode does not know") }
        guard let original = object["original"] as? [String: Any],
              let enabled = original["mclEnabled"] as? Bool,
              let limit = original["mclLimit"] as? Int, limitRange.contains(limit),
              let optimized = original["optimizedChargingEnabled"] as? Bool else {
            return .unreadable("the original settings are missing or out of range")
        }
        guard let list = object["holders"] as? [[String: Any]], list.count <= maxHolders else {
            return .unreadable("the holders are missing or too many")
        }
        var holders: [ChargeHolder] = []
        for item in list {
            guard let uid = item["uid"] as? Int, (0...4_294_967_294).contains(uid),
                  let pid = item["pid"] as? Int, (0...4_194_304).contains(pid) else {
                return .unreadable("a holder is not a user and a process")
            }
            let holder = ChargeHolder(uid: UInt32(uid), pid: Int32(pid))
            if !holders.contains(holder) { holders.append(holder) }
        }
        return .record(SharedChargeRecord(
            original: NativeChargeState(mclEnabled: enabled, mclLimit: limit, optimizedChargingEnabled: optimized),
            holders: holders))
    }

    static func encode(_ record: SharedChargeRecord) -> Data? {
        let object: [String: Any] = [
            "version": 1,
            "original": ["mclEnabled": record.original.mclEnabled, "mclLimit": record.original.mclLimit,
                         "optimizedChargingEnabled": record.original.optimizedChargingEnabled],
            "holders": record.holders.map { ["uid": Int($0.uid), "pid": Int($0.pid)] },
        ]
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Read-only: nothing is created and nothing is written. nil when the file is there but cannot be read.
    public func peek() -> Contents? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 { return errno == ENOENT ? Contents.none : nil }
        defer { close(fd) }
        guard lock(fd, shared: true) else { return nil }
        defer { flock(fd, LOCK_UN) }
        return Self.read(fd)
    }

    // ── Under the lock ──────────────────────────────────────────────────────

    /// The file, open and locked exclusively, for the length of one decision. Every write goes through it.
    public final class Session {
        fileprivate let fd: Int32
        public let contents: Contents

        fileprivate init(fd: Int32) {
            self.fd = fd
            self.contents = ChargeRecordStore.read(fd)
        }

        /// Replace the file's contents in place (never by renaming over it), and flush. nil leaves no record. False
        /// when it could not be written.
        @discardableResult
        public func write(_ record: SharedChargeRecord?) -> Bool {
            var data = Data()
            if let record {
                guard let encoded = ChargeRecordStore.encode(record) else { return false }
                data = encoded
            }
            guard ftruncate(fd, 0) == 0 else { return false }
            var written = 0
            while written < data.count {
                let n = data.withUnsafeBytes { raw in
                    pwrite(fd, raw.baseAddress! + written, data.count - written, off_t(written))
                }
                guard n > 0 else { return false }
                written += n
            }
            return fsync(fd) == 0
        }
    }

    /// Run `body` with the file locked, creating the folder and the file if need be. nil when the folder or the file
    /// cannot be had (missing and not creatable, read-only, not a regular file) or the lock cannot be taken within
    /// the timeout, which is what a process that is stopped while holding it looks like.
    public func withExclusiveLock<T>(_ body: (Session) -> T) -> T? {
        guard ensureDirectory() else { return nil }
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o666)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        // The umask may have narrowed it; the next account must be able to write what this one created. Only the
        // owner can change it, and for anyone else it is already what it should be.
        _ = fchmod(fd, 0o666)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        guard lock(fd, shared: false) else { return nil }
        defer { flock(fd, LOCK_UN) }
        return body(Session(fd: fd))
    }

    /// Whether the file can be had at all: the folder made, the file made, both writable. How the controller finds
    /// out that two accounts cannot be told apart on this Mac.
    public func isUsable() -> Bool { withExclusiveLock { _ in true } ?? false }

    // ── The decisions ───────────────────────────────────────────────────────

    public enum Acquired: Equatable {
        /// No record was there: macOS was read, and what it said is written down, with this Anode the only holder.
        case recorded(NativeChargeState)
        /// A record was there: macOS's settings now are somebody's limit, not macOS's own. They are not written
        /// down; this Anode is added to the holders and the record already there stands.
        case adopted(NativeChargeState)
        /// No record, and macOS would not say what its settings are: nothing was written.
        case macOSUnreadable
    }

    /// Switching on. Under the lock: a record that is there is adopted, whoever holds it, live or stale (a record with
    /// only stale holders means an Anode died holding the limit: its record is the original). Only when there is none
    /// is macOS read and written down. Stale holders are dropped. nil when the file cannot be had or written.
    public func acquire(readMacOS: () -> NativeChargeState?) -> Acquired? {
        withExclusiveLock { s in
            switch s.contents {
            case .record(let r):
                let kept = r.holders.filter { $0.uid != me.uid && isLive($0) }
                guard s.write(SharedChargeRecord(original: r.original, holders: kept + [me])) else { return nil }
                return .adopted(r.original)
            case .none, .unreadable:
                guard let found = readMacOS() else { return .macOSUnreadable }
                guard s.write(SharedChargeRecord(original: found, holders: [me])) else { return nil }
                return .recorded(found)
            }
        } ?? nil
    }

    public enum Released: Equatable {
        /// This was the last live holder: `restore` ran. True when it worked and the record was cleared; false keeps
        /// the record, with nobody holding it, for the next launch of any account's Anode to lift.
        case restored(Bool)
        /// Another account's Anode is alive and holds the limit: nothing was put back and the record stands.
        case handedOver
        /// The file is there and is not a record: nothing is put back from it.
        case unreadable(String)
    }

    /// Putting back (switching off, quitting, uninstalling, lifting after an unclean exit). Under the lock: this
    /// account and the stale holders are removed. If another live holder remains, nothing is put back and the record
    /// stays. Otherwise `restore` is called with the original (nil when the file is empty: the record was lost) while
    /// the lock is held, so that no other Anode switches on in the middle and records half-restored settings, and it
    /// says whether everything was put back. nil when the file cannot be had or written.
    public func release(restore: (NativeChargeState?) -> Bool) -> Released? {
        withExclusiveLock { s in
            switch s.contents {
            case .unreadable(let why):
                return .unreadable(why)
            case .none:
                return .restored(restore(nil))
            case .record(let r):
                let others = liveOthers(r)
                if !others.isEmpty {
                    guard s.write(SharedChargeRecord(original: r.original, holders: others)) else { return nil }
                    return .handedOver
                }
                let ok = restore(r.original)
                guard s.write(ok ? nil : SharedChargeRecord(original: r.original, holders: [])) else { return nil }
                return .restored(ok)
            }
        } ?? nil
    }

    /// A record kept by an earlier build in this account's own preferences, moved into the file with this account as
    /// its holder, if the file has none. The holder's process is not known (pid 0), so it is stale: the launch that
    /// finds it lifts the limit, as for any run that did not quit. True when the file now holds a record of it.
    public func adopt(legacy original: NativeChargeState) -> Bool {
        withExclusiveLock { s in
            if case .record = s.contents { return true }
            return s.write(SharedChargeRecord(original: original, holders: [ChargeHolder(uid: me.uid, pid: 0)]))
        } ?? false
    }

    // ── Plumbing ────────────────────────────────────────────────────────────

    private func ensureDirectory() -> Bool {
        var info = stat()
        if lstat(directory, &info) == 0 { return (info.st_mode & S_IFMT) == S_IFDIR }
        // Sticky and open to everyone, like `/Users/Shared` itself: the next account must be able to write inside it,
        // and nobody can remove what another account put there.
        guard mkdir(directory, 0o1777) == 0 || errno == EEXIST else { return false }
        _ = chmod(directory, 0o1777)
        return true
    }

    private func lock(_ fd: Int32, shared: Bool) -> Bool {
        let deadline = Date().addingTimeInterval(lockTimeout)
        repeat {
            if flock(fd, (shared ? LOCK_SH : LOCK_EX) | LOCK_NB) == 0 { return true }
            usleep(10_000)
        } while Date() < deadline
        return false
    }

    fileprivate static func read(_ fd: Int32) -> Contents {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return .unreadable("could not be read") }
        guard info.st_size <= off_t(maxBytes) else { return .unreadable("larger than a record can be") }
        var data = Data(count: Int(info.st_size))
        var got = 0
        while got < data.count {
            let n = data.withUnsafeMutableBytes { raw in
                pread(fd, raw.baseAddress! + got, raw.count - got, off_t(got))
            }
            guard n > 0 else { break }
            got += n
        }
        return parse(data.prefix(got))
    }
}
