import Foundation
import PowerKit

// ── Ultra Low Power Mode: Low Power Mode, through the helper ────────────────
//
// `PowerModeControlling` over the one connection the app shares with the helper (`HelperConnection`), with a holder of its
// own. Two commands go over it: `enterLowPowerMode`, which switches macOS's Low Power Mode on and answers what it was,
// and `restorePowerMode(before:)`, which puts it back.
//
// THE CONNECTION IS HELD from a successful enter until the restore has been answered. The helper puts the power mode back
// itself when the socket it was asked on closes (a quit, a crash, a kill), and that rule only covers the mode while the
// socket is open: closing it is the way a crash is undone.
//
// A HELPER THAT SPEAKS LESS THAN 4 IS NEVER SENT EITHER COMMAND. It cannot decode them and closes the connection, which
// hands the fans back, ends a discharge and drops the Ready By plan. So each command is sent only after a hello, in the
// same exchange, has said 4: what `availability` guessed from an earlier one is not what decides it.
//
// Main thread. The connection is, and `restore` can be asked from the work queue (recovery at launch), so both hop to it.
// Every callback comes once, on the main thread.

final class HelperPowerMode: PowerModeControlling {

    /// How long `enterLowPower` waits before it answers "could not". The session waits on this answer, and the link itself
    /// can take two seconds for the hello and two for the command.
    static let answerWithin: TimeInterval = 6

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
            let answer = Answer(done)
            // Bounded: the session waits on this. When the time is up the socket is let go (which, if the helper did take
            // the command, makes it put the mode back); an answer that comes after is dealt with below.
            schedule(Self.answerWithin) { [weak self] in
                if answer.finish(nil) { self?.connection.release(.powerMode) }
            }
            connection.connect(for: .powerMode) { [weak self] status in
                guard let self, !answer.isFinished else { return }
                guard case .connected(_, let spoken) = status, HelperConnection.speaksPowerMode(version: spoken) else {
                    self.connection.release(.powerMode)
                    answer.finish(nil)
                    return
                }
                self.connection.send(.enterLowPowerMode) { [weak self] reply in
                    guard let self else { return }
                    guard reply.ok, let before = reply.powerModeBefore, PowerModes(packed: before) != nil else {
                        self.connection.release(.powerMode)
                        answer.finish(nil)
                        return
                    }
                    // Kept held. An answer that has come too late has been told "could not", so nobody recorded the mode:
                    // it is put back here, at once.
                    if !answer.finish(before) {
                        self.connection.send(.restorePowerMode(before: before)) { _ in }
                    }
                }
            }
        }
    }

    func restore(_ mode: Int, _ done: @escaping (Bool) -> Void) {
        onMain { [self] in
            connection.connect(for: .powerMode) { [weak self] status in
                guard let self else { return done(false) }
                guard case .connected(_, let spoken) = status, HelperConnection.speaksPowerMode(version: spoken) else {
                    self.connection.release(.powerMode)
                    return done(false)
                }
                self.connection.send(.restorePowerMode(before: mode)) { [weak self] reply in
                    // Let go whatever the answer: a refused put-back is the helper's own second try, when the socket closes.
                    self?.connection.release(.powerMode)
                    done(reply.ok)
                }
            }
        }
    }

    private func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }

    /// One answer, given once. Main thread.
    private final class Answer {
        private var done: ((Int?) -> Void)?

        init(_ done: @escaping (Int?) -> Void) { self.done = done }

        var isFinished: Bool { done == nil }

        /// True when this was the answer; false when one had been given.
        @discardableResult
        func finish(_ value: Int?) -> Bool {
            guard let done else { return false }
            self.done = nil
            done(value)
            return true
        }
    }
}
