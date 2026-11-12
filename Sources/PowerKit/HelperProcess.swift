import Foundation

// The root helper's own process: which signals it survives, and where its log
// lines go. In PowerKit rather than in the executable so the test suite can pin
// both — while a discharge runs, the charger stays cut until THIS process
// reconnects it, so an exit it did not choose leaves the battery draining with
// nobody watching the floor.

/// What the helper does with each signal that could end or freeze it.
public enum HelperSignals {

    /// Every catchable signal whose default action ends the process. Each one
    /// takes the same path as ⌃C: `stop()`, then the loop's way out reconnects
    /// the charger and hands the fans back.
    ///
    /// SIGHUP is closing the Terminal window; SIGQUIT is ⌃\ in it. The rest are
    /// a stray `kill` away. SIGKILL and SIGSTOP cannot be caught, and are the
    /// documented limit: the next helper to start clears a cut nobody owns.
    public static let stop: [Int32] = [
        SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGUSR1, SIGUSR2, SIGALRM, SIGXCPU, SIGXFSZ,
    ]

    /// Ignored outright.
    ///
    /// SIGPIPE: a log reader that died (`AnodeHelper 2>&1 | tee log`, then ⌃C)
    /// would otherwise kill the helper on its next line, charger cut.
    /// SIGTSTP, SIGTTIN, SIGTTOU: ⌃Z, or a background write to the terminal,
    /// would SUSPEND it — alive to every check, enforcing nothing. A root
    /// helper holding the charger is never suspended.
    public static let ignored: [Int32] = [SIGPIPE, SIGTSTP, SIGTTIN, SIGTTOU]

    /// Ignore `ignored`. Call before anything else, so no write can raise
    /// SIGPIPE and no keystroke can stop the process.
    public static func ignoreTheOnesThatMustNotLand() {
        for sig in ignored { signal(sig, SIG_IGN) }
    }

    /// Route every `stop` signal to `onStop`.
    ///
    /// DispatchSource rather than a signal(3) handler: a handler runs on the
    /// interrupted thread with only async-signal-safe calls available, and
    /// `stop()` is called from it. SIG_IGN first, or the default action kills
    /// the process before the source sees the signal. Hold the returned sources
    /// for the life of the process; a released source stops firing.
    public static func routeToStop(queue: DispatchQueue = .global(),
                                   _ onStop: @escaping () -> Void) -> [DispatchSourceSignal] {
        stop.map { sig in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler(handler: onStop)
            source.resume()
            return source
        }
    }
}

/// The helper's stderr line, best effort, and unable to end the process.
public enum HelperLog {

    /// Write one line to `fd` (stderr) if that can be done without waiting.
    ///
    /// NEVER throws, never raises a signal, never blocks. The sink it replaces,
    /// `FileHandle.standardError.write`, raises an Objective-C exception on EIO
    /// — a Terminal window closed under a session helper — and the process
    /// aborted with the charger cut. A dead pipe was SIGPIPE, the same ending.
    /// And a stderr nobody drains (`| less`, or ⌃S in the window) would block
    /// the helper's only thread, which is the thread that watches the floor.
    ///
    /// So: no SIGPIPE on this descriptor whatever the process disposition
    /// (`F_SETNOSIGPIPE`), no write unless poll says there is room, at most
    /// PIPE_BUF bytes per write (a pipe takes that much at once or not at all),
    /// and a line that cannot go is dropped. The unified log is the record; this
    /// is the courtesy copy for whoever is watching the Terminal.
    @discardableResult
    public static func line(_ text: String, to fd: Int32 = STDERR_FILENO) -> Bool {
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        let bytes = Array((text + "\n").utf8)
        var sent = 0
        while sent < bytes.count {
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&p, 1, 0) == 1, p.revents & Int16(POLLOUT) != 0 else { return false }
            let chunk = min(bytes.count - sent, Int(PIPE_BUF))
            let n = bytes.withUnsafeBufferPointer { raw in
                write(fd, raw.baseAddress! + sent, chunk)
            }
            if n > 0 { sent += n; continue }
            if n < 0 && errno == EINTR { continue }
            return false
        }
        return true
    }
}
