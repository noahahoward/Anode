import Foundation
import Security
import os

/// Fan control is the one path in this project that CANNOT be exercised without
/// root, so it is the one path where a failure has to explain itself after the
/// fact. Every connect, refusal and command lands here.
///
///     log show --predicate 'subsystem == "dev.noah.anode"' --last 10m
///
/// Written after the first real privileged run did nothing visible and left no
/// trace to diagnose: the fans read 0 rpm, `F0Tg` read 0, and there was no way
/// to tell whether the app never connected, was refused, or wrote and was
/// ignored by the SMC. Those are three different bugs.
public let fanLog = Logger(subsystem: "dev.noah.anode", category: "fan")

// The channel between Anode and the one privileged thing it does.
//
// ─────────────────────────────────────────────────────────────────────────────
// THE TRUST MODEL, IN PLAIN WORDS. Read this before changing anything here.
//
// Fan control needs an SMC write, an SMC write needs root, and this project has
// no Apple Developer ID and will not get one — it is unfunded and open source.
// That rules out SMJobBless/SMAppService, which are the mechanisms that make
// launchd verify a signature before installing a privileged helper.
//
// What was tried first, and why it was abandoned: a root LaunchDaemon listening
// on a named Mach service, accepting only clients whose cdhash matched one
// pinned in a root-owned file at install time. The check itself was sound. The
// OPERATIONS were not. This app is distributed as source, so every user builds
// it locally, and an ad-hoc signature's cdhash changes on every single rebuild.
// The pin therefore went stale after every `./build-app.sh`, the daemon failed
// closed, and the repair was another admin-authorised install. That trains a
// user to type their password whenever an app asks — which is a worse hole than
// the one the pin closed, and it is not fixable by writing more code around it.
//
// So THAT daemon is gone. What replaced it is the default to this day — it is
// what you get if you never press Install, and the second half of this note says
// what pressing Install changes:
//
//   * NOTHING IS INSTALLED. There is no LaunchDaemon, no plist, no pin file and
//     no root process running when you are not using fan control. The helper is
//     a program the user starts by hand, with sudo, when they want fan control,
//     and it exits when they stop it.
//   * The rendezvous is a unix socket in a ROOT-OWNED directory (/var/run),
//     chowned to the user who started the helper and chmod 0600. Another user on
//     the machine cannot open it, and cannot create it either, because only root
//     can write to the directory it lives in.
//   * Every connection is checked twice: the kernel's own answer to "who is on
//     the other end" (`getpeereid`), and the caller's cdhash taken from the
//     peer's audit token. The pinned hash is computed AT HELPER STARTUP from the
//     app bundle the helper shipped inside — never read from a file, never
//     persisted. This is the whole answer to the rebuild problem: the pin cannot
//     go stale, because it lives and dies with the helper process.
//
// WHAT THIS STOPS: another user on the machine driving your fans; any program
// at all driving them while the helper is not running, which is almost always;
// a different program of yours driving them while it IS running, because its
// cdhash will not match. Re-signing ad-hoc under the same identifier does not
// defeat it — a cdhash is a hash of the code, so a different program produces a
// different hash whatever it calls itself.
//
// WHAT A USER GIVES UP BY ENABLING IT: while the helper is running there is a
// root process on the machine that will write fan targets on request. If an
// attacker can already run code as root they can do this and everything else
// anyway; if they can run code as you, they must ALSO be running from a binary
// whose cdhash matches your Anode build to be heard at all. The helper's
// entire vocabulary is "set fan N to R rpm" and "release the fans", R is
// re-clamped against limits read fresh from the hardware, and it can read and
// write nothing else.
//
// WHAT IT IS NOT: it is not the guarantee SMJobBless gives, because nothing
// verified the helper binary itself before it ran as root. The user did, by
// choosing the path they typed after `sudo`. That is a real check by a person
// rather than a cryptographic one by launchd, and calling it anything stronger
// would be the overstatement this file exists to avoid.
//
// ─────────────────────────────────────────────────────────────────────────────
// AND THEN: THE SECOND WAY, because typing a sudo command every session is not
// something to ask of anyone who is not developing this.
//
// Everything above still stands and is still the default. What was added is an
// INSTALL — one authorisation, once, after which fan control works across
// rebuilds and reboots and never asks again. `FanDaemon.swift` holds it, and the
// reasoning for the route is written out there. The two are alternatives, and the
// helper refuses to run as a session helper while the daemon is installed, so
// there is never a question of which one owns the socket.
//
// The one thing that has to be understood HERE, because it is a change to this
// file's own security argument, is the pin. The session helper pins ONE BUILD by
// cdhash — see `FanClientPin.exactBuild` — and that is the strongest check
// available to an unsigned project. An installed daemon cannot use it: it outlives
// every rebuild, and a hash pinned at install time is stale the next time
// `./build-app.sh` runs. So the daemon pins the SIGNING IDENTIFIER instead, and
// that is genuinely weaker:
//
//   * still enforced, and still by the kernel: the connection must come from the
//     uid that installed it. Another user on this machine is refused.
//   * still enforced: the caller must have a signature that VERIFIES. A tampered
//     or unsigned program produces no identity and is refused.
//   * NOT enforced any more: that the caller is the Anode you built. Anyone
//     who can run `codesign -s - -i dev.noah.anode` on their own binary
//     satisfies it. That is one command, and anything running as you can run it.
//
// So, in plain words, WHAT INSTALLING GIVES UP: from the moment you install,
// anything running as your user can set your fan speeds, at any time, until you
// uninstall. Not another user, and nothing at all before you install — but the
// "it must be exactly this app" claim is gone, and no amount of code brings it
// back without a Developer ID, because an ad-hoc signature has no key an attacker
// cannot also use.
//
// WHAT IS LEFT AS THE ACTUAL BOUNDARY, and it is not nothing: the vocabulary is
// two commands — set one fan to one speed, and release. Every speed is re-clamped
// against limits read fresh from the fan itself, so the reachable range is the
// range the hardware already permits its own controller. There is no key-name
// input, no path input, and nothing to read back. An attacker who takes it gets
// to make your machine loud, or to hold a fan at a speed the firmware would also
// hold it at; the SMC arbitrates and has been observed clamping a written target
// UPWARD. It is a nuisance, not a foothold.
//
// If that trade is not worth it — and for a developer rebuilding all day it is
// not — do not install. `sudo AnodeHelper` still works exactly as it always
// did, still pins one build, and still stops with ⌃C.
// ─────────────────────────────────────────────────────────────────────────────

/// Where the helper listens, and where the app looks for it.
///
/// `/var/run` is root-owned (755) and cleared at boot, which buys two things: no
/// other user can substitute a socket at this path and impersonate the helper,
/// and a socket file left behind by a hard kill never survives a restart.
public enum FanSocket {
    public static let path = "/var/run/anode-fan.sock"
}

// ── Wire format ─────────────────────────────────────────────────────────────

/// One request. `FanCommand` — which already existed, and already had a
/// round-trip test — remains the whole PRIVILEGED vocabulary; `hello` is wrapped
/// around it rather than added to it, because it writes nothing and does not
/// belong in a type whose documented job is naming what root is allowed to do.
public enum FanRequest: Codable, Equatable {
    /// Liveness and fan count. Writes nothing.
    case hello
    case command(FanCommand)
}

public struct FanReply: Codable, Equatable {
    public let ok: Bool
    public let message: String
    /// Fans the helper can see. Set only on the reply to `hello`; nil elsewhere
    /// means "not answered here", not "no fans".
    public let fanCount: Int?
    /// The protocol the answering helper speaks, on the reply to `hello`.
    ///
    /// Only the INSTALLED daemon needs this. It is a frozen copy taken at install
    /// time and it does not change when the app is rebuilt — which is the whole
    /// point of copying it, and also the one way this design can rot silently. An
    /// app that speaks a newer protocol than the daemon answering it can say so
    /// and offer to reinstall, instead of failing in some way nobody can read.
    /// nil is an older helper, which by definition speaks version 1.
    public let version: Int?

    public init(ok: Bool, message: String, fanCount: Int? = nil, version: Int? = nil) {
        self.ok = ok
        self.message = message
        self.fanCount = fanCount
        self.version = version
    }
}

/// Newline-delimited JSON, one message per line.
///
/// The line cap is not tidiness. The peer of a root process must not be able to
/// make it allocate without bound by never sending a newline; a request is a few
/// dozen bytes, so anything approaching this is not ours and the connection is
/// dropped rather than buffered.
public enum FanWire {
    public static let maxLineBytes = 4096

    public enum Failure: Error, Equatable {
        case lineTooLong
        case malformed
        case closed
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        guard let v = try? JSONDecoder().decode(type, from: line) else {
            throw Failure.malformed
        }
        return v
    }
}

// ── Who is on the other end ─────────────────────────────────────────────────

/// The caller of a connected socket, as the kernel and the code-signing
/// machinery describe it.
public struct FanPeer: Equatable {
    /// Effective uid, from `getpeereid`. Kernel-supplied and not forgeable by
    /// the peer.
    public let euid: uid_t
    /// The caller's cdhash, or nil when it has no valid signature. nil is a
    /// refusal, never a pass — see `FanAccess`.
    public let cdhash: String?
    /// The caller's signing identifier — `dev.noah.anode` for this app,
    /// taken from `CFBundleIdentifier` when the bundle was signed.
    ///
    /// It is here because it is the one part of an ad-hoc code identity that
    /// SURVIVES A REBUILD, and the installed daemon has to. It is also, unlike
    /// the cdhash, a string anyone can choose: `codesign -s - -i
    /// dev.noah.anode` on any binary at all produces a valid signature
    /// claiming this identifier. `FanAccess` says what that does and does not
    /// buy.
    public let signingIdentifier: String?

    public init(euid: uid_t, cdhash: String?, signingIdentifier: String? = nil) {
        self.euid = euid
        self.cdhash = cdhash
        self.signingIdentifier = signingIdentifier
    }

    /// Inspect a connected socket.
    ///
    /// The audit token comes from `LOCAL_PEERTOKEN`, not from the peer's pid. A
    /// pid can be recycled between the check and the use — the caller exits, the
    /// kernel reissues its pid to someone else's process, and the connection
    /// that was approved now belongs to them. An audit token names one process
    /// instance and cannot be recycled. (`LOCAL_PEERTOKEN` is declared in
    /// `sys/un.h`; it is the socket equivalent of the private `auditToken`
    /// property XPC clients are validated through.)
    public static func of(socket fd: Int32) -> FanPeer? {
        var uid = uid_t(0), gid = gid_t(0)
        guard getpeereid(fd, &uid, &gid) == 0 else { return nil }

        var token = audit_token_t()
        var len = socklen_t(MemoryLayout<audit_token_t>.size)
        let rc = withUnsafeMutablePointer(to: &token) {
            getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, $0, &len)
        }
        // No token means no identity. Returning a peer with a nil hash — rather
        // than nil for the whole peer — keeps the refusal in one place, where it
        // can say which of the two checks failed.
        guard rc == 0, len == socklen_t(MemoryLayout<audit_token_t>.size) else {
            return FanPeer(euid: uid, cdhash: nil)
        }
        let identity = FanIdentity.identity(auditToken: token)
        return FanPeer(euid: uid, cdhash: identity?.cdhash,
                       signingIdentifier: identity?.identifier)
    }
}

/// A code identity: who the binary says it is, and what it actually contains.
///
/// The two travel together because neither is usable alone. The cdhash is a hash
/// of the code and cannot be claimed falsely, but it changes on every rebuild.
/// The identifier survives rebuilds and can be claimed by anybody. Which of them
/// a given helper pins is `FanClientPin`, and the difference is the difference
/// between the two ways of running this feature.
public struct FanCodeIdentity: Equatable {
    public let cdhash: String
    public let identifier: String?

    public init(cdhash: String, identifier: String?) {
        self.cdhash = cdhash
        self.identifier = identifier
    }
}

/// Code identities, from a running process or from a bundle on disk.
///
/// Both sides of the pin go through here so they cannot drift: the helper hashes
/// the app bundle at startup with `cdhash(atPath:)`, and hashes each caller with
/// `cdhash(auditToken:)`. Verified equal for the same binary in
/// `FanIdentityTests`.
public enum FanIdentity {

    /// The identity of a running process, or nil if it has no valid signature.
    public static func identity(auditToken token: audit_token_t) -> FanCodeIdentity? {
        var t = token
        let data = withUnsafeBytes(of: &t) { Data($0) }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil,
                                             [kSecGuestAttributeAudit: data] as CFDictionary,
                                             [], &code) == errSecSuccess,
              let code else { return nil }
        // Validity first: a tampered caller must fail to produce an identity at
        // all rather than merely fail to match one. This is also what makes the
        // signing identifier worth reading — an identifier from a signature that
        // does not verify is just a string in a file.
        guard SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        return identity(of: staticCode)
    }

    /// The identity of a bundle or bare executable on disk.
    public static func identity(atPath path: String) -> FanCodeIdentity? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL,
                                          [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        return identity(of: staticCode)
    }

    /// The cdhash of a running process, or nil if it has no valid signature.
    public static func cdhash(auditToken token: audit_token_t) -> String? {
        identity(auditToken: token)?.cdhash
    }

    /// The cdhash of a bundle or bare executable on disk.
    public static func cdhash(atPath path: String) -> String? {
        identity(atPath: path)?.cdhash
    }

    private static func identity(of code: SecStaticCode) -> FanCodeIdentity? {
        var infoCF: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &infoCF) == errSecSuccess,
              let info = infoCF as? [String: Any],
              let cdhash = info[kSecCodeInfoUnique as String] as? Data else { return nil }
        return FanCodeIdentity(cdhash: cdhash.map { String(format: "%02x", $0) }.joined(),
                               identifier: info[kSecCodeInfoIdentifier as String] as? String)
    }
}

/// Which client a helper will listen to.
///
/// There are two, they are not interchangeable, and the difference is the whole
/// reason both ways of running this feature exist.
public enum FanClientPin: Equatable {

    /// ONE EXACT BUILD, by content hash.
    ///
    /// The session helper's pin. It is computed at startup from the app bundle
    /// the helper shipped inside, never persisted, and it dies with the process —
    /// so it cannot go stale, and a rebuild is handled by restarting the helper
    /// you were going to have to restart anyway. Nothing else can satisfy it: a
    /// cdhash is a hash of the code, so a different program produces a different
    /// hash whatever it calls itself.
    case exactBuild(cdhash: String)

    /// ANY BUILD CARRYING THIS SIGNING IDENTIFIER.
    ///
    /// The installed daemon's pin, and the honest cost of installing anything at
    /// all without a Developer ID. The daemon outlives every rebuild, so it
    /// cannot pin a hash that changes on every rebuild without turning the
    /// install button into "reinstall after every build" — which is the treadmill
    /// this project already rejected once, because it trains a user to type their
    /// password whenever an app asks.
    ///
    /// WHAT IT STOPS: another user on this machine (that check is the kernel's,
    /// and it runs first); any program with no valid signature; any program
    /// signed under a different identifier; a tampered copy of Anode,
    /// whose signature no longer verifies at all.
    ///
    /// WHAT IT DOES NOT STOP, said plainly: a program already running as you that
    /// signs itself ad-hoc under our identifier. Measured, not guessed —
    ///
    ///     cc -o notmine t.c && codesign -s - -i dev.noah.anode notmine
    ///     Identifier=dev.noah.anode   Signature=adhoc   valid on disk
    ///
    /// An ad-hoc signature has no key an attacker cannot also use, so there is no
    /// version of this check that a same-user attacker cannot satisfy. Naming a
    /// certificate in a requirement would fix it and costs a Developer ID. Until
    /// then this is a guard against accidents, other users and other programs —
    /// not against code that is already you.
    case signingIdentifier(String)
}

/// Whether a connection may drive the fans.
///
/// A pure function of what was observed, so every refusal can be tested without
/// root, without a helper, and without a machine that has fans. The helper calls
/// exactly this and does nothing else with the answer.
public enum FanAccess {

    public enum Decision: Equatable {
        case accept
        case refuse(String)
    }

    public static func decide(peer: FanPeer, ownerUID: uid_t, pin: FanClientPin) -> Decision {
        // The kernel's answer first, because it is the one an attacker cannot
        // influence at all. The helper serves the single user who started it;
        // root is not that user unless the user is root.
        guard peer.euid == ownerUID else {
            return .refuse("connection from uid \(peer.euid); this helper serves uid \(ownerUID)")
        }
        // No valid signature is a refusal under EITHER pin, and it is checked
        // before either. Under `.signingIdentifier` this is the load-bearing
        // half: an identifier read out of a signature that does not verify is
        // just a string in a file.
        guard let hash = peer.cdhash else {
            return .refuse("caller has no readable code signature")
        }
        switch pin {
        case .exactBuild(let pinned):
            guard hash == pinned else {
                // The ordinary cause is a rebuild: the running helper was started
                // for the previous binary. Said in those words because a user who
                // reads "identity mismatch" reaches for sudo, and the actual
                // repair is to stop the helper and start it again — or not to.
                return .refuse("caller is not the build this helper was started for "
                             + "(\(hash.prefix(12))… vs \(pinned.prefix(12))…)")
            }
        case .signingIdentifier(let wanted):
            guard let claimed = peer.signingIdentifier else {
                return .refuse("caller's signature carries no identifier")
            }
            guard claimed == wanted else {
                return .refuse("caller signs as \(claimed); this helper serves \(wanted)")
            }
        }
        return .accept
    }
}

// ── Socket plumbing shared by both ends ─────────────────────────────────────

enum FanSocketIO {

    /// Fill a `sockaddr_un` for `path`, or nil if the path cannot fit.
    ///
    /// `sun_path` is 104 bytes on Darwin and truncation would silently bind the
    /// wrong path, so a long path is refused rather than shortened.
    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }

    static func withAddress<T>(_ addr: inout sockaddr_un,
                               _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// Give a socket a deadline in both directions, and stop a hang-up from
    /// killing the process.
    ///
    /// The deadline: without it a helper that stopped answering would hang
    /// whoever is talking to it — on the app side that is the thread the window
    /// is drawn on, so the symptom would be a beachball rather than an error.
    ///
    /// SO_NOSIGPIPE: writing to a socket the other end has closed raises SIGPIPE,
    /// whose default disposition TERMINATES the process. The peer closing is not
    /// an exceptional case here — it is what the helper does to a caller it
    /// refuses, and what a stopped helper does to the app — so without this a
    /// perfectly ordinary refusal would take Anode down with it.
    static func configure(_ fd: Int32, timeout seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds),
                         tv_usec: Int32((seconds - seconds.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var sent = 0
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            while sent < raw.count {
                let n = write(fd, base + sent, raw.count - sent)
                if n > 0 { sent += n; continue }
                // EINTR is a signal arriving mid-write, not a failure.
                if n < 0 && errno == EINTR { continue }
                return false
            }
            return true
        }
    }

    /// Read one newline-terminated line, capped. Throws `.closed` at EOF so the
    /// caller can tell a clean hang-up from a protocol error — the difference
    /// between "the app quit" and "something is talking nonsense at a root
    /// process", which deserve different responses.
    static func readLine(_ fd: Int32, buffer: inout Data) throws -> Data {
        while true {
            if let idx = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<idx]
                buffer.removeSubrange(buffer.startIndex...idx)
                return Data(line)
            }
            guard buffer.count <= FanWire.maxLineBytes else { throw FanWire.Failure.lineTooLong }
            var chunk = [UInt8](repeating: 0, count: 1024)
            let n = read(fd, &chunk, chunk.count)
            if n > 0 { buffer.append(contentsOf: chunk[0..<n]); continue }
            if n < 0 && errno == EINTR { continue }
            throw FanWire.Failure.closed
        }
    }
}

// ── The app's end ───────────────────────────────────────────────────────────

/// The app's connection to a running fan helper.
///
/// All socket work happens on a private serial queue and every answer is
/// delivered on the main thread, because the alternative is a blocking write to
/// a root process on the thread that draws the window.
public final class FanControlLink {

    public enum Status: Equatable {
        case disconnected
        /// Nothing is listening. The ordinary state: the helper only runs when
        /// the user has started it.
        case notRunning
        /// The helper is there and would not have us. Carries its reason
        /// verbatim, because the reason is the whole value of the message.
        case refused(String)
        /// `version` is what the answering helper speaks. An INSTALLED daemon is
        /// a frozen copy and can be older than the app talking to it; carrying
        /// its version here is what lets the app notice instead of failing in
        /// some way nobody can read. nil is a helper from before the field
        /// existed, i.e. version 1.
        case connected(fanCount: Int, version: Int?)
    }

    private let socketPath: String
    private let queue = DispatchQueue(label: "com.anode.fanlink", qos: .userInitiated)
    private var fd: Int32 = -1
    private var buffer = Data()

    public init(socketPath: String = FanSocket.path) {
        self.socketPath = socketPath
    }

    deinit { if fd >= 0 { close(fd) } }

    /// Open the socket and say hello. Writes nothing to any fan.
    public func connect(_ done: @escaping (Status) -> Void) {
        queue.async { [self] in
            let status = openAndGreet()
            DispatchQueue.main.async { done(status) }
        }
    }

    /// Is the helper still there?
    ///
    /// A `hello` round trip and nothing else — it writes no fan target, which is
    /// what makes it safe to run on a timer. The app needs this because a helper
    /// that dies while nothing is being dragged is otherwise invisible: the
    /// socket sits open on our side until something tries to use it, and until
    /// then the strip would go on saying fans are under manual control that were
    /// handed back seconds ago.
    ///
    /// Never reconnects. Re-opening the socket would look to the helper like the
    /// client disappearing and RELEASE THE FANS, which is the exact opposite of
    /// what a liveness check is for.
    public func ping(_ done: @escaping (Status) -> Void) {
        queue.async { [self] in
            let status: Status
            if fd < 0 {
                status = .notRunning
            } else if let reply = exchange(.hello) {
                status = reply.ok
                    ? .connected(fanCount: reply.fanCount ?? 0, version: reply.version)
                    : .refused(reply.message)
            } else {
                status = .notRunning
            }
            DispatchQueue.main.async { done(status) }
        }
    }

    public func send(_ command: FanCommand, _ done: @escaping (FanReply) -> Void) {
        queue.async { [self] in
            fanLog.info("sending \(String(describing: command), privacy: .public)")
            let reply = exchange(.command(command))
                ?? FanReply(ok: false, message: "the fan helper stopped answering")
            fanLog.info("reply ok=\(reply.ok) — \(reply.message, privacy: .public)")
            DispatchQueue.main.async { done(reply) }
        }
    }

    /// Drop the connection without asking the helper for anything.
    ///
    /// This is also how the app hands the fans back when it quits, and it is
    /// deliberately the SAME path a crash takes: the helper releases the fans
    /// when its client disappears, so the disaster path is the one exercised
    /// every time the app is closed normally, rather than the one nobody ever
    /// runs until it matters.
    public func disconnect() {
        queue.sync { [self] in
            if fd >= 0 { close(fd); fd = -1 }
            buffer.removeAll()
        }
    }

    // ── on the queue ────────────────────────────────────────────────────────

    private func openAndGreet() -> Status {
        if fd >= 0 { close(fd); fd = -1 }
        buffer.removeAll()

        guard var addr = FanSocketIO.address(socketPath) else {
            return .refused("the helper's socket path is too long for a unix socket")
        }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return .refused("could not create a socket") }
        FanSocketIO.configure(s, timeout: 2)
        // `Darwin.` qualified: this type has its own `connect(_:)`, and the
        // unqualified name resolves to it.
        let rc = FanSocketIO.withAddress(&addr) { p, len in Darwin.connect(s, p, len) }
        guard rc == 0 else {
            let why = String(cString: strerror(errno))
            fanLog.info("connect(\(self.socketPath, privacy: .public)) failed: \(why, privacy: .public)")
            close(s)
            // ENOENT: no socket file. ECONNREFUSED: the file is there but nobody
            // is listening, which is what a hard-killed helper leaves behind.
            // Both mean the same thing to a user and neither is an error.
            return (errno == ENOENT || errno == ECONNREFUSED)
                ? .notRunning
                : .refused(String(cString: strerror(errno)))
        }
        fd = s

        guard let reply = exchange(.hello) else {
            fanLog.error("connected, but the helper closed without answering hello")
            return .refused("the fan helper closed the connection without answering")
        }
        guard reply.ok else {
            fanLog.error("helper REFUSED this app: \(reply.message, privacy: .public)")
            close(fd); fd = -1
            return .refused(reply.message)
        }
        fanLog.info("connected — helper reports \(reply.fanCount ?? 0) fan(s)")
        return .connected(fanCount: reply.fanCount ?? 0, version: reply.version)
    }

    private func exchange(_ request: FanRequest) -> FanReply? {
        guard fd >= 0, let data = try? FanWire.encode(request) else {
            if fd >= 0 { close(fd); fd = -1 }
            return nil
        }
        // The write result is deliberately ignored. A helper that refuses this
        // caller answers with the REASON and then closes, so our write can fail
        // with EPIPE while the sentence explaining it is already sitting in the
        // receive buffer. Reading regardless is what turns "the helper stopped
        // answering" back into the message that says what to do about it; if the
        // write really did fail and there is nothing to read, the read hits EOF
        // and we end up in the same place anyway.
        _ = FanSocketIO.writeAll(fd, data)
        guard let line = try? FanSocketIO.readLine(fd, buffer: &buffer),
              let reply = try? FanWire.decode(FanReply.self, from: line) else {
            close(fd); fd = -1
            return nil
        }
        return reply
    }
}
