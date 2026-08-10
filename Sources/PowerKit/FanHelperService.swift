import Foundation

// The privileged half of fan control: what root actually does, and the socket it
// listens on while a user has deliberately started it. `FanLink` states the trust
// model this implements; read that first.

// ── The hardware, behind a protocol ─────────────────────────────────────────

/// The three things the helper is allowed to do to a fan.
///
/// A protocol rather than a direct `SMC` call so the server's whole control flow
/// — clamping, the release-on-disconnect, the refusals — can be exercised in the
/// test suite against a fake. Writing to a real fan to find out whether the code
/// works is not a test, it is a thermal event.
public protocol FanHardware: AnyObject {
    /// How many fans this helper could actually drive: indices whose min and max
    /// both read. NOT an inventory of the machine's fans — a fan with unreadable
    /// limits exists and is simply not controllable, which is the distinction
    /// this count is for.
    func controllableFanCount() -> Int
    func limits(index: Int) -> FanPolicy.Limits?
    func writeTarget(index: Int, rpm: Double) -> Bool
}

/// Hand every fan back to macOS.
///
/// ONE implementation, called by the server's dead man's switch, by the explicit
/// "Return to automatic" request, and by `--uninstall`. Three copies of a write
/// this consequential is three chances for one of them to drift.
public enum FanRelease {

    public struct Result: Equatable {
        /// Fans that took the write.
        public let released: Int
        /// Fans that had readable limits and refused it. Non-zero means the
        /// machine is NOT fully handed back.
        public let refused: Int
        public var ok: Bool { refused == 0 }

        public var message: String {
            switch (released, refused) {
            case (_, let r) where r > 0:
                return "\(r) fan(s) did not accept the release — they may still be held"
            case (0, _):
                return "no controllable fan found to release"
            case (1, _):
                return "1 fan returned to automatic control"
            default:
                return "\(released) fans returned to automatic control"
            }
        }
    }

    /// Writes each fan's own MINIMUM target, deliberately not zero. Zero is a
    /// request to STOP the fan, and a firmware that honoured it literally on a
    /// warm machine would be the worst possible outcome of a function whose
    /// entire job is "stop meddling".
    @discardableResult
    public static func all(hardware: FanHardware, maxFanIndex: Int = 8) -> Result {
        var released = 0, refused = 0
        for i in 0..<maxFanIndex {
            guard let l = hardware.limits(index: i) else { continue }
            if hardware.writeTarget(index: i, rpm: l.minRPM) { released += 1 } else { refused += 1 }
        }
        return Result(released: released, refused: refused)
    }
}

/// `FanHardware` over the real SMC. Needs root for the writes; the reads do not.
public final class SMCFanHardware: FanHardware {
    private let smc: SMC?
    private let maxFanIndex: Int

    public init(smc: SMC? = SMC(), maxFanIndex: Int = 8) {
        self.smc = smc
        self.maxFanIndex = maxFanIndex
    }

    public func controllableFanCount() -> Int {
        (0..<maxFanIndex).filter { limits(index: $0) != nil }.count
    }

    public func limits(index: Int) -> FanPolicy.Limits? {
        guard let smc,
              let mn = smc.read("F\(index)Mn")?.value,
              let mx = smc.read("F\(index)Mx")?.value else { return nil }
        return FanPolicy.Limits(minRPM: mn, maxRPM: mx)
    }

    public func writeTarget(index: Int, rpm: Double) -> Bool {
        smc?.writeFloat("F\(index)Tg", rpm) ?? false
    }
}

// ── The server ──────────────────────────────────────────────────────────────

/// The helper's socket, its access check, and the two operations behind it.
///
/// Lives in PowerKit rather than in the helper executable so the test suite can
/// run a real server, over a real socket, against fake hardware, as an ordinary
/// user. Everything here except the SMC writes is exercised that way.
public final class FanHelperServer {

    public struct Configuration {
        public var socketPath: String
        /// The user this helper serves — the one who started it. Every other uid
        /// is refused.
        public var ownerUID: uid_t
        /// The client's cdhash, computed at STARTUP from the app bundle on disk.
        /// Never read from a file: a persisted pin goes stale on the next
        /// rebuild, and repairing it is an admin prompt.
        public var pinnedCDHash: String
        /// Fan indices scanned by a release. Eight rather than the reported fan
        /// count, so a machine whose `FNum` under-reports still has every fan
        /// handed back.
        public var maxFanIndex: Int

        public init(socketPath: String = FanSocket.path,
                    ownerUID: uid_t,
                    pinnedCDHash: String,
                    maxFanIndex: Int = 8) {
            self.socketPath = socketPath
            self.ownerUID = ownerUID
            self.pinnedCDHash = pinnedCDHash
            self.maxFanIndex = maxFanIndex
        }
    }

    public enum Failure: Error, LocalizedError, Equatable {
        case badPath(String)
        case socketFailed(String)

        public var errorDescription: String? {
            switch self {
            case .badPath(let p):       return "\(p) cannot be a unix socket path"
            case .socketFailed(let why): return "could not listen on the fan socket: \(why)"
            }
        }
    }

    private let hardware: FanHardware
    private let config: Configuration
    private let log: (String) -> Void

    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var clientBuffer = Data()
    private var wakePipe: [Int32] = [-1, -1]

    /// Written by whoever calls `stop()` — a signal source on another queue — and
    /// read by the accept loop. Behind a lock rather than a bare `Bool`: the
    /// compiler cannot see the cross-thread write, so a plain property read is a
    /// value the loop's `while` is entitled to hoist and never re-check, and the
    /// failure mode is a root process that will not stop.
    private let stateLock = NSLock()
    private var stoppingFlag = false
    private var stopping: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return stoppingFlag }
        set { stateLock.lock(); stoppingFlag = newValue; stateLock.unlock() }
    }

    /// Has this helper written a fan target at all?
    ///
    /// The default mode writes NOTHING — not even a "set it back to automatic"
    /// write — so a user who starts the helper and then changes their mind must
    /// end up on a machine this process never touched. Release is therefore a
    /// no-op until something has actually been set.
    public private(set) var hasWrittenATarget = false

    public init(hardware: FanHardware,
                configuration: Configuration,
                log: @escaping (String) -> Void = { _ in }) {
        self.hardware = hardware
        self.config = configuration
        self.log = log
    }

    /// Bind and listen. Separate from `run()` so a caller — or a test — knows the
    /// socket is ready before anything tries to connect to it.
    public func start() throws {
        guard var addr = FanSocketIO.address(config.socketPath) else {
            throw Failure.badPath(config.socketPath)
        }
        // A socket file left by a hard-killed helper would make bind fail with
        // EADDRINUSE even though nobody is listening. Removing it is safe here
        // and nowhere else: only root can write this directory.
        unlink(config.socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socketFailed(String(cString: strerror(errno))) }
        guard FanSocketIO.withAddress(&addr, { p, len in bind(fd, p, len) }) == 0 else {
            let why = String(cString: strerror(errno))
            close(fd)
            throw Failure.socketFailed(why)
        }
        // bind() applies the umask, so the mode has to be set explicitly. 0600
        // plus an owner who is the user who started the helper is the access
        // control — the socket lives in a root-owned directory, so no one else
        // can replace it either.
        if chmod(config.socketPath, 0o600) != 0 {
            log("warning: could not chmod the socket: \(String(cString: strerror(errno)))")
        }
        if config.ownerUID != geteuid(),
           chown(config.socketPath, config.ownerUID, gid_t(bitPattern: -1)) != 0 {
            let why = String(cString: strerror(errno))
            close(fd)
            unlink(config.socketPath)
            throw Failure.socketFailed("could not hand the socket to uid "
                                     + "\(config.ownerUID): \(why)")
        }
        guard listen(fd, 4) == 0 else {
            let why = String(cString: strerror(errno))
            close(fd)
            unlink(config.socketPath)
            throw Failure.socketFailed(why)
        }

        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else {
            let why = String(cString: strerror(errno))
            close(fd)
            unlink(config.socketPath)
            throw Failure.socketFailed(why)
        }
        wakePipe = pipeFDs
        listenFD = fd
        log("listening on \(config.socketPath) for uid \(config.ownerUID)")
    }

    /// Serve until `stop()`. Blocking; one client at a time.
    public func run() {
        while !stopping {
            var fds = [pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: wakePipe[0], events: Int16(POLLIN), revents: 0)]
            if clientFD >= 0 {
                fds.append(pollfd(fd: clientFD, events: Int16(POLLIN), revents: 0))
            }
            guard poll(&fds, nfds_t(fds.count), -1) >= 0 || errno == EINTR else { break }
            if stopping { break }

            if fds[1].revents & Int16(POLLIN) != 0 {
                var scratch = [UInt8](repeating: 0, count: 16)
                _ = read(wakePipe[0], &scratch, scratch.count)
            }
            if fds.count > 2, fds[2].revents != 0 { serveClientReadable() }
            if fds[0].revents & Int16(POLLIN) != 0 { acceptOne() }
        }
        shutdownSocket()
    }

    /// Wake the loop and let it unwind. Safe to call from another thread — it
    /// only writes one byte to a pipe.
    public func stop() {
        stopping = true
        if wakePipe[1] >= 0 {
            var byte: UInt8 = 1
            _ = write(wakePipe[1], &byte, 1)
        }
    }

    // ── Connections ─────────────────────────────────────────────────────────

    private func acceptOne() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        FanSocketIO.configure(fd, timeout: 5)

        guard let peer = FanPeer.of(socket: fd) else {
            refuse(fd, "the kernel would not identify the caller")
            return
        }
        switch FanAccess.decide(peer: peer,
                                ownerUID: config.ownerUID,
                                pinnedCDHash: config.pinnedCDHash) {
        case .refuse(let why):
            log("refused a connection: \(why)")
            refuse(fd, why)
            return
        case .accept:
            break
        }
        // One client at a time. Two programs taking turns at the same fan is a
        // fight the user cannot see, and the second one is told why rather than
        // left waiting on a socket nobody is reading.
        guard clientFD < 0 else {
            log("refused a second client while one is connected")
            refuse(fd, "another BetterStats window already has fan control")
            return
        }
        clientFD = fd
        clientBuffer.removeAll()
        log("client connected")
    }

    private func refuse(_ fd: Int32, _ why: String) {
        // Say no out loud. A connection that is simply closed leaves the app
        // showing "the helper stopped answering", which is the same message a
        // crash produces and tells the user nothing about what to do.
        if let data = try? FanWire.encode(FanReply(ok: false, message: why)) {
            _ = FanSocketIO.writeAll(fd, data)
        }
        close(fd)
    }

    private func serveClientReadable() {
        do {
            let line = try FanSocketIO.readLine(clientFD, buffer: &clientBuffer)
            let request = try FanWire.decode(FanRequest.self, from: line)
            let reply = handle(request)
            if let data = try? FanWire.encode(reply), !FanSocketIO.writeAll(clientFD, data) {
                dropClient(reason: "the client stopped reading")
            }
        } catch FanWire.Failure.closed {
            dropClient(reason: "the client disconnected")
        } catch {
            dropClient(reason: "malformed request (\(error))")
        }
    }

    /// The client went away — quit, crashed, or was killed. Hand the fans back.
    ///
    /// This is the dead man's switch, and it is the reason the app closes its
    /// socket on quit rather than sending a polite goodbye: the crash path and
    /// the ordinary-quit path are then the same path, so the one that matters
    /// gets exercised every day instead of never.
    private func dropClient(reason: String) {
        guard clientFD >= 0 else { return }
        close(clientFD)
        clientFD = -1
        clientBuffer.removeAll()
        log("client gone (\(reason))")
        let reply = release()
        log(reply.message)
    }

    private func shutdownSocket() {
        // Order matters: release while the SMC is still ours to talk to, then
        // take the socket away so nothing can reconnect mid-teardown.
        if clientFD >= 0 { dropClient(reason: "the helper is stopping") }
        else { log(release().message) }
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(config.socketPath)
        for fd in wakePipe where fd >= 0 { close(fd) }
        wakePipe = [-1, -1]
        log("stopped")
    }

    // ── Operations ──────────────────────────────────────────────────────────

    func handle(_ request: FanRequest) -> FanReply {
        switch request {
        case .hello:
            return FanReply(ok: true, message: "fan helper ready",
                            fanCount: hardware.controllableFanCount())
        case .command(.setTarget(let target)):
            return set(target)
        case .command(.releaseAll):
            return release()
        }
    }

    private func set(_ target: FanTarget) -> FanReply {
        // Bounded before the index reaches a key name. FanPolicy would refuse an
        // absent fan anyway, but an unbounded index is how a request turns into
        // an arbitrary four-character SMC key.
        guard target.index >= 0, target.index < config.maxFanIndex else {
            return FanReply(ok: false, message: "refused: fan index out of range")
        }
        // Re-clamped HERE, against limits read fresh from the hardware. The app
        // clamps too, but a privileged process that trusts its client's
        // arithmetic is not actually a boundary.
        switch FanPolicy.resolve(rpm: target.rpm, limits: hardware.limits(index: target.index)) {
        case .failure(let why):
            return FanReply(ok: false, message: "refused: \(why)")
        case .success(let safe):
            guard hardware.writeTarget(index: target.index, rpm: safe) else {
                return FanReply(ok: false, message: "the SMC refused the write")
            }
            hasWrittenATarget = true
            log("set F\(target.index)Tg = \(safe)")
            return FanReply(ok: true,
                            message: "fan \(target.index + 1) set to \(Int(safe)) rpm")
        }
    }

    @discardableResult
    private func release() -> FanReply {
        // The default mode writes NOTHING, so a helper that was started and never
        // used must leave a machine it has not touched — including on the way
        // out. Releasing unconditionally here would write a target to a fan
        // under perfectly good automatic control.
        guard hasWrittenATarget else {
            return FanReply(ok: true,
                            message: "nothing to release — this helper has written no fan target")
        }
        let result = FanRelease.all(hardware: hardware, maxFanIndex: config.maxFanIndex)
        // Left set on a partial failure so a later release tries again rather
        // than reporting a machine as handed back when one fan was not.
        if result.ok { hasWrittenATarget = false }
        return FanReply(ok: result.ok, message: result.message)
    }
}

// ── Uninstall ───────────────────────────────────────────────────────────────

/// Everything this project has ever asked root to leave on a disk, and how to
/// take it all back off again.
///
/// The list is longer than the current design creates ON PURPOSE. An earlier
/// draft of fan control installed a LaunchDaemon, a privileged helper binary and
/// a pinned-cdhash file; anyone who ran that draft still has them, and an
/// uninstall that only cleaned up after the design that replaced it would leave a
/// root daemon behind while reporting success. Nothing here is created by the
/// shipped code except the socket.
public enum FanHelperInstall {

    /// The label the retired LaunchDaemon was loaded under. Kept so `--uninstall`
    /// can boot it out of launchd, which removing the plist alone does not do.
    public static let retiredDaemonLabel = "dev.noah.betterstats.helper"

    public struct Artifacts {
        /// Removed if present, in this order — the pin before the directory that
        /// holds it.
        public let files: [URL]
        /// Removed only when empty, so a future version storing something else
        /// under Application Support does not lose it to a fan uninstaller.
        public let directoriesIfEmpty: [URL]

        public var all: [URL] { files + directoriesIfEmpty }
    }

    /// `root` is "/" in production and a temporary directory under test, which is
    /// the only way to prove the uninstall actually removes what it claims
    /// without running it as root against a live system.
    public static func artifacts(root: URL = URL(fileURLWithPath: "/")) -> Artifacts {
        Artifacts(
            files: [
                // The retired design's three pieces.
                root.appendingPathComponent("Library/LaunchDaemons/\(retiredDaemonLabel).plist"),
                root.appendingPathComponent("Library/PrivilegedHelperTools/\(retiredDaemonLabel)"),
                root.appendingPathComponent("Library/Application Support/BetterStats/client.cdhash"),
                // The only artifact the shipped design creates, and only while
                // the helper is actually running.
                root.appendingPathComponent(String(FanSocket.path.dropFirst())),
            ],
            directoriesIfEmpty: [
                root.appendingPathComponent("Library/Application Support/BetterStats"),
            ])
    }

    public enum Outcome: Equatable {
        case removed
        case absent
        /// A directory that still holds something we did not put there.
        case notEmpty
        case failed(String)
    }

    public struct Removal: Equatable {
        public let path: String
        public let outcome: Outcome
    }

    public static func removeArtifacts(root: URL = URL(fileURLWithPath: "/"),
                                       fileManager fm: FileManager = .default) -> [Removal] {
        let a = artifacts(root: root)
        var out: [Removal] = []

        for url in a.files {
            guard fm.fileExists(atPath: url.path) else {
                out.append(Removal(path: url.path, outcome: .absent)); continue
            }
            do {
                try fm.removeItem(at: url)
                out.append(Removal(path: url.path, outcome: .removed))
            } catch {
                out.append(Removal(path: url.path, outcome: .failed(error.localizedDescription)))
            }
        }

        for url in a.directoriesIfEmpty {
            guard fm.fileExists(atPath: url.path) else {
                out.append(Removal(path: url.path, outcome: .absent)); continue
            }
            let contents = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
            // .DS_Store is Finder's, not the user's, and refusing to remove a
            // directory because Finder looked at it would strand it forever.
            guard contents.allSatisfy({ $0 == ".DS_Store" }) else {
                out.append(Removal(path: url.path, outcome: .notEmpty)); continue
            }
            do {
                try fm.removeItem(at: url)
                out.append(Removal(path: url.path, outcome: .removed))
            } catch {
                out.append(Removal(path: url.path, outcome: .failed(error.localizedDescription)))
            }
        }
        return out
    }
}
