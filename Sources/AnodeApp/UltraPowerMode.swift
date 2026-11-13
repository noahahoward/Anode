import Foundation
import PowerKit

// ── Ultra Low Power Mode: Low Power Mode, through the helper ────────────────
//
// `PowerModeControlling` over the one connection the app shares with the helper (`HelperConnection`), with a holder of its
// own. Three commands go over it: `enterLowPowerMode`, which switches macOS's Low Power Mode on, `restorePowerMode(before:)`,
// which puts it back, and `powerModeResult`, which says how the last of the two ended. The helper runs `pmset` off its loop,
// so the first two answer "started" at once and this polls the third every `pollEvery` seconds until it says done or failed,
// or until `answerWithin` seconds have passed: the helper answers each request at once, so the link's own two-second wait
// is never what ends it.
//
// THE CONNECTION IS HELD from a successful enter until the restore has been answered. The helper puts the power mode back
// itself when the socket it was asked on closes (a quit, a crash, a kill), and that rule only covers the mode while the
// socket is open: closing it is the way a crash is undone.
//
// AN ENTER THAT IS NOT ANSWERED IN TIME is answered "could not", and still watched for `watchWithin` seconds: the helper may
// well have taken it, and a "before" that arrives late is put back at once, because nobody recorded it. The holder is kept
// for that long, so the socket stays open to poll on, and let go when the watch ends (which, if nobody else holds it, closes
// the socket and so makes the helper put back whatever it holds).
//
// THE SOCKET IS SHARED, and Charge Control relies on it not being closed or reset while it holds its own claim. So this
// uses the claim and release of `HelperConnection` only: it connects through `connect(for:)`, never closes the link, and
// sends nothing once the connection is down (a send that finds no socket never opens one, and is not made).
//
// A HELPER THAT SPEAKS LESS THAN 4 IS NEVER SENT ANY OF THEM. It cannot decode them and closes the connection, which hands
// the fans back, ends a discharge and drops the Ready By plan. So each is sent only after a hello, in the same exchange, has
// said 4: what `availability` guessed from an earlier one is not what decides it.
//
// Main thread. The connection is, and `restore` can be asked from the work queue (recovery at launch), so both hop to it.
// Every callback comes once, on the main thread.

final class HelperPowerMode: PowerModeControlling {

    /// How long `enterLowPower` and `restore` wait for the helper's answer before saying "could not". The session waits on
    /// this answer.
    static let answerWithin: TimeInterval = 3

    /// How often the helper is asked how its job is going.
    static let pollEvery: TimeInterval = 0.2

    /// How long, from the start, an enter that was answered "could not" is still watched for the "before" that would say
    /// the helper took it after all. The helper's slowest switch-on is a little under five seconds (the worker's six calls
    /// when a write fails and is rolled back), and this is longer than that.
    static let watchWithin: TimeInterval = 8

    private let connection: HelperConnection
    private let isInstalled: () -> Bool
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private var token: AnyObject?
    /// What the helper last said it speaks; nil before it has said anything, and while it is being replaced.
    private var version: Int?

    init(connection: HelperConnection = .shared, isInstalled: @escaping () -> Bool = { FanDaemon.isInstalled() },
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { after, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + after, execute: work)
         }) {
        self.connection = connection
        self.isInstalled = isInstalled
        self.schedule = schedule
        heard()
        token = connection.watch { [weak self] in self?.heard() }
    }

    /// Whoever talks to the helper (the Fans tab, Charge Control, this) tells everyone what it speaks, so it is known
    /// without a connection of its own. An install or an uninstall is about to change it.
    private func heard() {
        if case .connected(_, let spoken) = connection.status {
            version = spoken ?? 1
        } else if connection.suspended {
            version = nil
        }
    }

    /// `.noHelper` when none is installed and none is connected (one started by hand counts); `.oldHelper` when it has
    /// said it speaks less than 4; `.ready` otherwise, which includes an installed helper that has not been heard from yet:
    /// the hello before each command decides then, and what it says is remembered.
    var availability: PowerModeAvailability {
        guard isInstalled() || connection.isConnected else { return .noHelper }
        guard let version else { return .ready }
        return HelperConnection.speaksPowerMode(version: version) ? .ready : .oldHelper
    }

    func enterLowPower(_ done: @escaping (Int?) -> Void) {
        onMain { [self] in
            let attempt = Attempt()
            let answer = Once(done)
            // Bounded: the session waits on this. Past it the answer is "could not", but an enter that was sent is still
            // watched (below); one that was not has nothing to watch for, and lets go.
            schedule(Self.answerWithin) { [weak self] in
                answer.finish(nil)
                if !attempt.sent { self?.end(attempt) }
            }
            schedule(Self.watchWithin) { [weak self] in
                answer.finish(nil)
                self?.end(attempt)
            }
            connection.connect(for: .powerMode) { [weak self] status in
                guard let self, !attempt.over else { return }
                guard case .connected(_, let spoken) = status, HelperConnection.speaksPowerMode(version: spoken) else {
                    self.end(attempt)
                    answer.finish(nil)
                    return
                }
                attempt.sent = true
                self.connection.send(.enterLowPowerMode) { [weak self] reply in
                    guard let self, !attempt.over else { return }
                    guard reply.ok else {
                        self.end(attempt)
                        answer.finish(nil)
                        return
                    }
                    self.pollEnter(attempt, answer)
                }
            }
        }
    }

    /// Ask how the enter is going, and again after `pollEvery` while it is pending. First at once: the helper answers a
    /// request whatever its tool is doing.
    private func pollEnter(_ attempt: Attempt, _ answer: Once<Int?>) {
        guard !attempt.over else { return }
        guard connection.isConnected, !connection.suspended else {
            end(attempt)
            answer.finish(nil)
            return
        }
        connection.send(.powerModeResult) { [weak self] reply in
            guard let self, !attempt.over else { return }
            if reply.pending == true {
                self.schedule(Self.pollEvery) { [weak self] in self?.pollEnter(attempt, answer) }
                return
            }
            guard reply.ok, let before = reply.powerModeBefore, PowerModes(packed: before) != nil else {
                self.end(attempt)
                answer.finish(nil)
                return
            }
            attempt.over = true
            // Kept held. An answer that has come too late has been told "could not", so nobody recorded the mode: it is put
            // back here, at once, and the claim is let go once the helper has the command.
            if !answer.finish(before) {
                self.connection.send(.restorePowerMode(before: before)) { [weak self] _ in
                    self?.connection.release(.powerMode)
                }
            }
        }
    }

    func restore(_ mode: Int, _ done: @escaping (Bool) -> Void) {
        onMain { [self] in
            let attempt = Attempt()
            let answer = Once(done)
            schedule(Self.answerWithin) { [weak self] in
                // Let go: a put-back that is still not done is the helper's own, when the socket closes.
                self?.end(attempt)
                answer.finish(false)
            }
            connection.connect(for: .powerMode) { [weak self] status in
                guard let self, !attempt.over else { return }
                guard case .connected(_, let spoken) = status, HelperConnection.speaksPowerMode(version: spoken) else {
                    self.end(attempt)
                    answer.finish(false)
                    return
                }
                self.connection.send(.restorePowerMode(before: mode)) { [weak self] reply in
                    guard let self, !attempt.over else { return }
                    guard reply.ok else {
                        self.end(attempt)
                        answer.finish(false)
                        return
                    }
                    self.pollRestore(attempt, answer)
                }
            }
        }
    }

    private func pollRestore(_ attempt: Attempt, _ answer: Once<Bool>) {
        guard !attempt.over else { return }
        guard connection.isConnected, !connection.suspended else {
            end(attempt)
            answer.finish(false)
            return
        }
        connection.send(.powerModeResult) { [weak self] reply in
            guard let self, !attempt.over else { return }
            if reply.pending == true {
                self.schedule(Self.pollEvery) { [weak self] in self?.pollRestore(attempt, answer) }
                return
            }
            // Let go whatever the answer: a refused put-back is the helper's own second try, when the socket closes.
            self.end(attempt)
            answer.finish(reply.ok)
        }
    }

    /// This attempt is done with the connection: nothing more is polled or sent for it, and its claim is let go (the socket
    /// closes only if nobody else holds it). Once.
    private func end(_ attempt: Attempt) {
        guard !attempt.over else { return }
        attempt.over = true
        connection.release(.powerMode)
    }

    private func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }

    /// One enter or restore, as far as the polling and the timers go. Main thread.
    private final class Attempt {
        /// Nothing more is sent or asked for it.
        var over = false
        /// The enter command has been put on the socket, so the helper may have taken it whatever it answered.
        var sent = false
    }

    /// One answer, given once. Main thread.
    private final class Once<Value> {
        private var done: ((Value) -> Void)?

        init(_ done: @escaping (Value) -> Void) { self.done = done }

        /// True when this was the answer; false when one had been given.
        @discardableResult
        func finish(_ value: Value) -> Bool {
            guard let done else { return false }
            self.done = nil
            done(value)
            return true
        }
    }
}
