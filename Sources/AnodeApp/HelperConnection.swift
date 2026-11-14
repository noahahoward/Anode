import Foundation
import PowerKit

// ── The one connection to the helper ────────────────────────────────────────
//
// The helper serves ONE client at a time and turns a second away ("another Anode window already has fan control").
// When its client's socket closes it takes the client as gone: it hands the fans back AND reconnects the charger,
// ending a discharge. Two parts of this app talk to it, the Fans tab and Charge Control, so each holding a link of
// its own could not work: whichever connected second would be refused, and either one closing its socket would undo
// what the other had asked for.
//
// So there is one socket, owned here, and each user holds a claim on it:
//
//   * connecting greets over the socket that is already open (`FanControlLink.ensureConnected`) and never reopens
//     one that answers, because a reopen IS a client leaving;
//   * a user letting go closes the socket only when it was the last one holding it, so switching fan control off
//     does not end a discharge, and switching Charge Control off does not hand back fans the person is holding;
//   * installing or uninstalling the helper stops the daemon under the socket, so `suspend()` closes it for
//     everyone and holds off every reconnect until `resume()`.
//
// Quitting still lets go of every claim, the last of which closes the socket: the helper's dead man's switch
// remains the way the fans and the charger are handed back, on a quit as on a crash.
//
// Main thread only. Every answer arrives on the main thread, except `sendWaiting`'s, which is the point of it.

/// One socket's worth of talking to the helper. `FanControlLink` is the real one; a protocol so the sharing rules
/// can be tested with a scripted wire.
protocol HelperWire: AnyObject {
    func ensureConnected(_ done: @escaping (FanControlLink.Status, Bool) -> Void)
    func ping(_ done: @escaping (FanControlLink.Status) -> Void)
    func send(_ command: FanCommand, _ done: @escaping (FanReply) -> Void)
    func sendWaiting(_ command: FanCommand, timeout: TimeInterval) -> FanReply?
    func drain(timeout: TimeInterval) -> Bool
    func disconnect()
    /// Close after everything already sent, without waiting for it: see `FanControlLink.disconnectWithoutWaiting`.
    func disconnectWithoutWaiting()
    /// Called on the main thread when the helper closed the socket while nothing was on it: see
    /// `FanControlLink.onPeerClosed`.
    var onPeerClosed: (() -> Void)? { get set }
}

extension FanControlLink: HelperWire {}

final class HelperConnection {

    /// The app's connection. Inert until something asks it to connect: creating it opens nothing.
    static let shared = HelperConnection(wire: FanControlLink())

    /// What `FanControlLink` answers a command with when there is no socket, or the helper closed it without
    /// answering. The link never answers "nothing": this refusal is how a helper that is gone shows up.
    static let stoppedAnswering = "the Anode helper stopped answering"

    enum Holder: Hashable {
        case fans
        case charge
        /// Low Power Mode, from a successful switch-on until it is put back: the helper puts the mode back itself when
        /// the socket closes, so the socket is kept open for that long.
        case powerMode
        /// The look a newly installed or updated Anode takes at what the installed helper speaks, let go at once.
        case offer
    }

    private let wire: HelperWire
    /// Who wants the socket open. It is closed when the last of them lets go.
    private(set) var holders: Set<Holder> = []
    /// What the helper last said, from a connect, a ping or a failed command.
    private(set) var status: FanControlLink.Status = .disconnected
    /// Counts the moments the helper may have dropped what this app had asked of it: its socket closed or was
    /// replaced, or someone sent `.releaseAll` (which reconnects the charger as well as releasing the fans).
    /// Charge Control compares it to the count when its discharge started.
    private(set) var resets = 0
    /// True between `suspend()` and `resume()`.
    private(set) var suspended = false
    /// Bumped whenever the socket is closed here, so an answer to a connect made before the close is not taken for
    /// news about the socket after it.
    private var epoch = 0
    private var watchers: [UUID: () -> Void] = [:]

    init(wire: HelperWire) {
        self.wire = wire
        wire.onPeerClosed = { [weak self] in self?.peerClosed() }
    }

    /// The helper closed the socket between exchanges: it died, or was stopped. Until now that was seen only by the
    /// next exchange (up to 30 s on, and only while a discharge was on it), with `status` still saying connected and a
    /// charger that may be cut left with nobody watching it. Recorded as the socket going away, so `resets` goes up and
    /// everyone watching hears at once. Not for a socket closed here (`close`, which has already recorded it), nor one
    /// closed since this was sent from the link's queue.
    private func peerClosed() {
        guard isConnected, !suspended else { return }
        record(.disconnected)
    }

    var isConnected: Bool {
        if case .connected = status { return true }
        return false
    }

    /// Connected to a helper that knows the charge commands: protocol 2 or later. A helper too old to report a
    /// version speaks 1.
    var speaksCharge: Bool {
        if case .connected(_, let version) = status { return (version ?? 1) >= 2 }
        return false
    }

    /// Connected to a helper that knows the Low Power Mode commands: protocol 4 or later. A helper that speaks less closes
    /// the connection on a command it cannot decode, which hands the fans back, ends a discharge and drops the Ready By
    /// plan, so these commands go only to a helper that has just said 4.
    var speaksPowerMode: Bool {
        if case .connected(_, let version) = status { return Self.speaksPowerMode(version: version) }
        return false
    }

    static func speaksPowerMode(version: Int?) -> Bool { (version ?? 1) >= 4 }

    // ── Claims ──────────────────────────────────────────────────────────────

    /// Hold the socket open for `holder`, opening it if nobody has. An open socket that answers is greeted, never
    /// replaced.
    func connect(for holder: Holder, _ done: @escaping (FanControlLink.Status) -> Void) {
        holders.insert(holder)
        guard !suspended else { return done(.notRunning) }
        let asked = epoch
        wire.ensureConnected { [weak self] status, reopened in
            guard let self, self.epoch == asked, !self.suspended else {
                // The socket this answer is about has since been closed here.
                return done(.disconnected)
            }
            self.record(status, reopened: reopened)
            done(status)
        }
    }

    /// Let go. The socket closes only if nobody else is holding it; closing it is what tells the helper to hand
    /// everything back.
    func release(_ holder: Holder) {
        holders.remove(holder)
        guard holders.isEmpty else { return }
        close()
    }

    /// Close the socket for every user and refuse to reopen it until `resume()`. For installing and uninstalling
    /// the helper, which stop the daemon under an open socket: a user reconnecting meanwhile would start the old
    /// daemon again, or look to a surviving one like a second client.
    func suspend() {
        suspended = true
        close()
        // Told even when the socket was already closed: a user that is not holding it (Charge Control between
        // commands) still needs to know an install or uninstall is under way, to look again once it is over.
        notify()
    }

    /// The install or uninstall is over. Reconnect at once if anyone is still holding the socket.
    func resume() {
        suspended = false
        notify()
        guard !holders.isEmpty, let anyone = holders.first else { return }
        connect(for: anyone) { _ in }
    }

    /// Closed without waiting: everything here runs on the main thread (letting go while quitting, switching Charge
    /// Control off, an install), and a helper that has stopped answering would otherwise hold it for every exchange
    /// still queued. The close still lands after them, in order, and every answer to them is already stale (`epoch`).
    private func close() {
        epoch += 1
        wire.disconnectWithoutWaiting()
        record(.disconnected)
    }

    // ── Talking ─────────────────────────────────────────────────────────────

    /// A hello over the open socket. Never reconnects: see `FanControlLink.ping`.
    func ping(_ done: @escaping (FanControlLink.Status) -> Void) {
        let asked = epoch
        wire.ping { [weak self] status in
            if let self, self.epoch == asked { self.record(status) }
            done(status)
        }
    }

    func send(_ command: FanCommand, _ done: @escaping (FanReply) -> Void) {
        wire.send(command) { [weak self] reply in
            if !reply.ok { self?.checkStillThere() }
            done(reply)
        }
        // Announced after the command is on the wire, so anything sent in answer goes after it.
        if case .releaseAll = command {
            resets += 1
            notify()
        }
    }

    /// `send`, answered before it returns, or nil after `timeout`. Blocks the calling thread.
    func sendWaiting(_ command: FanCommand, timeout: TimeInterval) -> FanReply? {
        let reply = wire.sendWaiting(command, timeout: timeout)
        if reply?.ok != true { checkStillThere() }
        return reply
    }

    /// Wait until everything already sent has been exchanged with the helper, or `timeout`. Blocks the calling
    /// thread; see `FanControlLink.drain`.
    func drain(timeout: TimeInterval) -> Bool {
        wire.drain(timeout: timeout)
    }

    /// A command failed: find out whether the socket did too. `FanControlLink` closes a socket that stopped
    /// answering, and a ping then says so without opening another.
    private func checkStillThere() {
        ping { _ in }
    }

    // ── What changed ────────────────────────────────────────────────────────

    private func record(_ new: FanControlLink.Status, reopened: Bool = false) {
        let wasConnected = isConnected
        let old = status
        status = new
        var changed = old != new
        // A socket that went away, or a new one in its place: the helper released what the old one held.
        if (wasConnected && !isConnected) || (reopened && isConnected) {
            resets += 1
            changed = true
        }
        if changed { notify() }
    }

    /// Be told whenever `status`, `resets` or `suspended` changes. Retain the token; releasing it stops the calls.
    func watch(_ changed: @escaping () -> Void) -> AnyObject {
        let token = WatchToken(owner: self)
        watchers[token.id] = changed
        return token
    }

    private func notify() {
        for w in Array(watchers.values) { w() }
    }

    private final class WatchToken {
        let id = UUID()
        private weak var owner: HelperConnection?
        init(owner: HelperConnection) { self.owner = owner }
        deinit { owner?.watchers[id] = nil }
    }
}
