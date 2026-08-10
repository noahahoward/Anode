import Foundation

// The privileged half of fan control: what root actually does, and the socket it
// listens on while a user has deliberately started it. `FanLink` states the trust
// model this implements; read that first.

// ── The hardware, behind a protocol ─────────────────────────────────────────

/// The four things the helper is allowed to do to a fan.
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
    /// The fan's CURRENT target, or nil if it cannot be read.
    ///
    /// Read once per fan, immediately before this helper takes it, and kept.
    /// Release puts that value back — see `FanRelease` for why restoring an
    /// observed number beats asserting what "released" means.
    func readTarget(index: Int) -> Double?
}

/// What a helper remembers about the fans it has taken: THAT it took them, and
/// where each one was beforehand.
///
/// Both facts are needed and they are not the same fact. A fan whose original
/// target could not be read has still been taken, and must still be handed back
/// — dropping it from the record because there was no number to store is how a
/// held fan gets left pinned by the very function that exists to unpin it.
public struct FanHoldings: Equatable {

    /// Fans this helper has successfully written to. Membership, not the stored
    /// rpm, is what makes a fan eligible for release.
    private var taken: Set<Int> = []
    /// Where a taken fan was before we took it, when it could be read.
    private var previous: [Int: Double] = [:]

    public init() {}

    public var isEmpty: Bool { taken.isEmpty }
    /// Ascending, so a release writes fans in a fixed order and a test can say
    /// what it expects.
    public var indices: [Int] { taken.sorted() }

    public func wasTaken(_ index: Int) -> Bool { taken.contains(index) }
    public func previousTarget(of index: Int) -> Double? { previous[index] }

    /// Record a first write. Ignored for a fan already taken: our own earlier
    /// target must never overwrite the memory of what automatic looked like.
    public mutating func took(_ index: Int, previousTarget: Double?) {
        guard !taken.contains(index) else { return }
        taken.insert(index)
        if let previousTarget, previousTarget.isFinite { previous[index] = previousTarget }
    }

    public mutating func forgetAll() {
        taken.removeAll()
        previous.removeAll()
    }
}

/// Handing the fans back.
///
/// ONE implementation, called by the server's dead man's switch, by the explicit
/// "Return to automatic" request, and by `--uninstall`. Three copies of a write
/// this consequential is three chances for one of them to drift.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// MEASURED. The previous version of this was WRONG ON REAL HARDWARE, and it was
/// wrong in the loud direction. It wrote each fan's reported MINIMUM, reasoning
/// that zero is a request to STOP a fan and must never be sent. That reasoning
/// assumed a meaning these keys do not have on Apple silicon:
///
///     before anything was written   F0Tg = 0      F0Ac = 0 rpm    (cool, silent)
///     after "release" wrote 2317    F0Tg = 2317   F0Ac = 2320 rpm (audible)
///     after writing 0               F0Tg = 0      F0Ac = 0 rpm    (silent again)
///
/// So on this Mac 0 is "no forced target", i.e. AUTOMATIC. The old release did
/// not hand the fans back at all: it pinned them at minimum and made a silent
/// machine loud, for several minutes, on the user's own desk.
///
/// Two further things were measured at the same time and both argue for reading
/// rather than reasoning. The SMC ARBITRATES: writing 2317 to both fans left
/// `F0Tg = 2317` but `F1Tg = 2502`, because fan 1's firmware clamped it upward.
/// And there is no `F<n>Md` mode key and no Intel-style `FS!` bitmask on this
/// machine — only `FNum`, `F<n>Ac`, `F<n>Mn`, `F<n>Mx`, `F<n>Tg`. `F<n>Mn` is
/// therefore advice, not truth, and no semantics can be inferred from it.
/// ─────────────────────────────────────────────────────────────────────────────
public enum FanRelease {

    /// The value this hardware uses for "no forced target".
    ///
    /// Measured, not assumed — see above. It is written in exactly two places:
    /// by `toAutomatic`, which has no session history to restore; and as the
    /// fallback for a fan that WAS taken but whose original could not be read.
    /// Every other release puts back a number this code watched the machine
    /// report.
    public static let noForcedTarget: Double = 0

    public struct Result: Equatable {
        /// Which question the numbers answer, for wording only.
        public enum Kind: Equatable {
            /// Fans were put back where they were found.
            case restored
            /// Fans were set to `noForcedTarget` because there was nothing to
            /// restore from.
            case automatic
        }

        /// Fans that took the write.
        public let released: Int
        /// Fans that refused it. Non-zero means the machine is NOT fully handed
        /// back.
        public let refused: Int
        public let kind: Kind
        public var ok: Bool { refused == 0 }

        public init(released: Int, refused: Int, kind: Kind = .restored) {
            self.released = released
            self.refused = refused
            self.kind = kind
        }

        public var message: String {
            if refused > 0 {
                return "\(refused) fan(s) did not accept the release — they may still be held"
            }
            switch (kind, released) {
            case (.restored, 0): return "no fan was held — nothing to hand back"
            case (.restored, 1): return "1 fan put back the way it was found"
            case (.restored, let n): return "\(n) fans put back the way they were found"
            case (.automatic, 0): return "no controllable fan found to release"
            case (.automatic, 1): return "1 fan returned to automatic control"
            case (.automatic, let n): return "\(n) fans returned to automatic control"
            }
        }
    }

    /// Put back the target each held fan had BEFORE this helper first wrote to
    /// it, and touch nothing else.
    ///
    /// Restoring an observed value assumes nothing about what any number means.
    /// Whatever the machine was doing before this helper touched it — 0 here, a
    /// real rpm on some other Mac, something nobody has seen — is what it goes
    /// back to. That is the only definition of "release" that cannot be wrong on
    /// hardware this project has never run on, and this project ships to
    /// hardware nobody here has run on.
    ///
    /// A FAN THAT WAS NEVER TAKEN IS LEFT ALONE. Writing to a fan in order to
    /// "release" one we never held is precisely how the old bug happened, and it
    /// is why this walks the holdings rather than the fan indices.
    ///
    /// It also does not re-read `limits`. A fan we successfully wrote to is by
    /// definition controllable, and a limits read that has started failing must
    /// never be the reason a held fan is skipped.
    @discardableResult
    public static func all(hardware: FanHardware, holdings: FanHoldings) -> Result {
        var released = 0, refused = 0
        for i in holdings.indices {
            // The fallback is the automatic value, not the minimum. A fan we
            // took has to go back to something, and "minimum" is the number that
            // caused this bug; leaving it where we put it is worse still.
            let restore = holdings.previousTarget(of: i) ?? noForcedTarget
            if hardware.writeTarget(index: i, rpm: restore) { released += 1 } else { refused += 1 }
        }
        return Result(released: released, refused: refused, kind: .restored)
    }

    /// Set every fan this helper can see to `noForcedTarget`, for `--uninstall`.
    ///
    /// That command runs in a process holding no session history, so there is no
    /// "original" to restore and this writes the measured no-forced-target value
    /// instead. That IS an assumption, unlike the path above, and it is made
    /// only here: this command exists for "an app that pinned my fans has been
    /// deleted", and leaving them pinned is the exact failure it is there to
    /// fix. It reports what it did so the assumption is visible rather than
    /// silent.
    @discardableResult
    public static func toAutomatic(hardware: FanHardware, maxFanIndex: Int = 8) -> Result {
        var released = 0, refused = 0
        for i in 0..<maxFanIndex {
            guard hardware.limits(index: i) != nil else { continue }
            if hardware.writeTarget(index: i, rpm: noForcedTarget) { released += 1 }
            else { refused += 1 }
        }
        return Result(released: released, refused: refused, kind: .automatic)
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

    /// The forced target the fan is under right now. On this hardware a machine
    /// nobody has touched reads 0 here, which is what makes restoring it a
    /// release rather than a different kind of hold.
    public func readTarget(index: Int) -> Double? {
        smc?.read("F\(index)Tg")?.value
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
        /// Which client this helper will listen to.
        ///
        /// A session helper pins ONE BUILD, by a cdhash computed at startup from
        /// the app bundle on disk — never read from a file, because a persisted
        /// pin goes stale on the next rebuild and repairing it is an admin
        /// prompt. An installed daemon cannot do that, and pins the signing
        /// identifier instead. `FanClientPin` says exactly what each one buys.
        public var pin: FanClientPin
        /// Fan indices scanned by `toAutomatic`. Eight rather than the reported
        /// fan count, so a machine whose `FNum` under-reports still has every fan
        /// handed back.
        public var maxFanIndex: Int

        public init(socketPath: String = FanSocket.path,
                    ownerUID: uid_t,
                    pin: FanClientPin,
                    maxFanIndex: Int = 8) {
            self.socketPath = socketPath
            self.ownerUID = ownerUID
            self.pin = pin
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

    /// Did this process create the socket file, and may it therefore delete it?
    ///
    /// A session helper binds its own socket and unlinks it on the way out, so a
    /// stale path never outlives the process. An ON-DEMAND DAEMON MUST NOT: the
    /// socket belongs to launchd, which is still holding it and will use it to
    /// start the next helper. Unlinking it would make this the LAST helper that
    /// ever started — every later connection would find nothing at that path.
    private var ownsSocketPath = true

    /// How long to wait, with nothing connected and no fan held, before this
    /// helper stops. nil for a session helper, which is stopped by the person who
    /// started it and by nothing else.
    public var idleExit: TimeInterval?

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

    /// The fans this helper has taken, and where each was before it did.
    ///
    /// This is the whole memory a release works from. Emptied only by a CLEAN
    /// release: a partial failure keeps it, so the next attempt still knows
    /// where the fans belong.
    private var holdings = FanHoldings()

    /// Has this helper written a fan target at all?
    ///
    /// The default mode writes NOTHING — not even a "set it back to automatic"
    /// write — so a user who starts the helper and then changes their mind must
    /// end up on a machine this process never touched. Release is therefore a
    /// no-op until something has actually been set.
    public var hasWrittenATarget: Bool { !holdings.isEmpty }

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

    /// Serve a socket someone else created, bound and set listening — in
    /// practice, always launchd's.
    ///
    /// Nothing here binds, `chmod`s or `chown`s. The plist asked launchd for a
    /// socket owned by the serving user with mode 0600, which is exactly what
    /// `start()` sets by hand, and re-applying it from this side would be a
    /// second opinion about permissions with no way to tell which one won. What
    /// this does instead is CHECK, because adopting a descriptor that is not what
    /// we think it is would mean a root process serving something unexamined.
    public func start(adopting fd: Int32) throws {
        guard fd >= 0 else { throw Failure.socketFailed("launchd offered no descriptor") }

        // It must be a stream socket, and it must be bound to the path this
        // helper was configured to serve.
        //
        // NOT "and it must be listening": macOS has no way to ask that about a
        // unix socket. `SO_ACCEPTCONN` fails with ENOPROTOOPT on AF_UNIX both
        // before and after `listen()` — measured, not assumed, and an earlier
        // draft of this check used it and rejected every socket launchd offered.
        // Whether it is listening is launchd's side of the contract; what is
        // checkable here is that it is the right KIND of socket at the right
        // PATH, which is the part that would silently serve the wrong thing.
        var type: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &length) == 0 else {
            throw Failure.socketFailed("launchd's descriptor is not a socket: "
                                     + String(cString: strerror(errno)))
        }
        guard type == SOCK_STREAM else {
            throw Failure.socketFailed("launchd's socket is not a stream socket")
        }

        var bound = sockaddr_un()
        var boundLength = socklen_t(MemoryLayout<sockaddr_un>.size)
        let boundPath: String? = withUnsafeMutablePointer(to: &bound) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                guard getsockname(fd, sa, &boundLength) == 0 else { return nil }
                guard sa.pointee.sa_family == sa_family_t(AF_UNIX) else { return nil }
                return withUnsafePointer(to: &raw.pointee.sun_path) { tuple in
                    tuple.withMemoryRebound(to: CChar.self,
                                            capacity: MemoryLayout.size(ofValue: tuple.pointee)) {
                        String(cString: $0)
                    }
                }
            }
        }
        guard let boundPath else {
            throw Failure.socketFailed("launchd's socket is not a unix socket")
        }
        guard boundPath == config.socketPath else {
            throw Failure.socketFailed("launchd's socket is bound to \(boundPath), "
                                     + "but this helper serves \(config.socketPath)")
        }

        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else {
            // The socket is launchd's; it is not ours to close or unlink on the
            // way out of a failure.
            throw Failure.socketFailed(String(cString: strerror(errno)))
        }
        wakePipe = pipeFDs
        listenFD = fd
        ownsSocketPath = false
        log("serving launchd's socket at \(config.socketPath) for uid \(config.ownerUID)")
    }

    /// Serve until `stop()`, or — for the on-demand daemon — until there has been
    /// nothing to do for `idleExit`. Blocking; one client at a time.
    ///
    /// THE POLL BLOCKS FOREVER WHENEVER THERE IS ANYTHING TO WAIT FOR. A timeout
    /// is passed only when this helper is idle AND holding no fan, so a helper
    /// that is doing its job is never periodically woken: it costs no CPU and no
    /// wakeups at all between requests, which is the property that makes a root
    /// process defensible in the first place.
    ///
    /// A HELPER HOLDING A FAN NEVER TIMES OUT. Leaving runs the dead-man's
    /// switch, and handing the fans back is right when the app has died and
    /// wrong when it merely has nothing to say for ninety seconds.
    public func run() {
        var idleSince: Date? = Date()
        while !stopping {
            var fds = [pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: wakePipe[0], events: Int16(POLLIN), revents: 0)]
            if clientFD >= 0 {
                fds.append(pollfd(fd: clientFD, events: Int16(POLLIN), revents: 0))
            }

            let idling = clientFD < 0 && holdings.isEmpty
            if !idling { idleSince = nil }
            else if idleSince == nil { idleSince = Date() }

            var timeout: Int32 = -1
            if let idleExit, let idleSince, idling {
                let left = idleExit - Date().timeIntervalSince(idleSince)
                if left <= 0 {
                    log("idle for \(Int(idleExit))s with no fan held — stopping. "
                      + "launchd starts a new helper when the app next connects.")
                    break
                }
                timeout = Int32((left * 1000).rounded(.up))
            }

            guard poll(&fds, nfds_t(fds.count), timeout) >= 0 || errno == EINTR else { break }
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
                                pin: config.pin) {
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
        // Only if we made it. launchd's socket outlives this process on purpose:
        // it is what the next connection arrives on, and removing it would make
        // this the last helper that ever started.
        if ownsSocketPath { unlink(config.socketPath) }
        for fd in wakePipe where fd >= 0 { close(fd) }
        wakePipe = [-1, -1]
        log("stopped")
    }

    // ── Operations ──────────────────────────────────────────────────────────

    func handle(_ request: FanRequest) -> FanReply {
        switch request {
        case .hello:
            return FanReply(ok: true, message: "fan helper ready",
                            fanCount: hardware.controllableFanCount(),
                            version: FanDaemon.protocolVersion)
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
            // Where the fan is RIGHT NOW, read before the write that takes it and
            // only for a fan we have not taken already. This is the number the
            // release puts back, and there is exactly one moment it can be read.
            let before = holdings.wasTaken(target.index)
                ? nil : hardware.readTarget(index: target.index)
            guard hardware.writeTarget(index: target.index, rpm: safe) else {
                return FanReply(ok: false, message: "the SMC refused the write")
            }
            // Recorded only once the write actually landed. A refused write took
            // nothing, and a helper that believes it holds a fan it never touched
            // would write to that fan on its way out.
            holdings.took(target.index, previousTarget: before)
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
        guard !holdings.isEmpty else {
            return FanReply(ok: true,
                            message: "nothing to release — this helper has written no fan target")
        }
        let result = FanRelease.all(hardware: hardware, holdings: holdings)
        // Kept on a partial failure so a later release tries again rather than
        // reporting a machine as handed back when one fan was not.
        if result.ok { holdings.forgetAll() }
        return FanReply(ok: result.ok, message: result.message)
    }
}

// ── Uninstall ───────────────────────────────────────────────────────────────

/// Everything this project has ever asked root to leave on a disk, and how to
/// take it all back off again.
///
/// The list is longer than any single design creates ON PURPOSE. Three versions
/// of this feature have existed: a first draft that installed a LaunchDaemon and
/// a pinned-cdhash file; the session helper, which installs NOTHING and leaves
/// only a socket; and the current optional daemon (`FanDaemon`). Anyone may be
/// running any of them, and an uninstall that only cleaned up after the newest
/// would leave a root daemon behind while reporting success.
///
/// This enum is the REMOVE side. `FanDaemonInstall` is the add side, and every
/// path it creates has to appear here or the uninstall is a lie.
public enum FanHelperInstall {

    /// The label the retired LaunchDaemon was loaded under. Kept so `--uninstall`
    /// can boot it out of launchd, which removing the plist alone does not do.
    public static let retiredDaemonLabel = "dev.noah.betterstats.helper"

    /// Every launchd label this project has ever loaded, oldest first. Booted out
    /// before their plists are removed: removing a plist does not unload a job
    /// that is already running, and a bootout after the file is gone has nothing
    /// to name.
    public static var daemonLabels: [String] { [retiredDaemonLabel, FanDaemon.label] }

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
                // The current optional install: a plist and a root-owned copy of
                // the helper. Absent unless the user pressed Install Fan Helper.
                root.appendingPathComponent(String(FanDaemon.plistPath.dropFirst())),
                root.appendingPathComponent(String(FanDaemon.helperPath.dropFirst())),
                // Created by whichever helper is running, and only while it runs.
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
