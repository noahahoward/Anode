import Foundation

// ── A thread for event taps ─────────────────────────────────────────────────
//
// An event tap is part of the system's input path: until its callback returns, the event waits, for every
// app on the Mac. Run on the main thread, a tap is only as fast as the main thread, so anything that keeps
// the main thread busy (a call into an app that does not answer, a layout, a redraw) holds up the mouse or
// keyboard of the WHOLE machine, and the system switches a tap that is too slow off for good. That is what
// a user saw during a FaceTime call: the pointer froze while a window was dragged, came back, and the
// feature never worked again.
//
// So the taps whose callbacks only note what happened (and answer "pass it on") run here instead, on a
// thread that does nothing else, and hand what they saw to the main thread.

final class EventTapThread {
    static let shared = EventTapThread()

    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)

    private init() {
        let thread = Thread { [unowned self] in
            self.runLoop = CFRunLoopGetCurrent()
            // A run loop with nothing to watch returns at once; a port keeps it alive.
            RunLoop.current.add(Port(), forMode: .default)
            self.ready.signal()
            while true { RunLoop.current.run(mode: .default, before: .distantFuture) }
        }
        thread.name = "Anode event taps"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    func add(_ source: CFRunLoopSource) {
        guard let runLoop else { return }
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CFRunLoopWakeUp(runLoop)
    }

    func remove(_ source: CFRunLoopSource) {
        guard let runLoop else { return }
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        CFRunLoopWakeUp(runLoop)
    }
}

/// A mach port shared between the main thread (which makes and drops a tap) and the tap thread (which
/// must switch it back on if the system turned it off).
final class TapPortBox {
    private let lock = NSLock()
    private var port: CFMachPort?

    var value: CFMachPort? {
        get { lock.lock(); defer { lock.unlock() }; return port }
        set { lock.lock(); port = newValue; lock.unlock() }
    }
}

/// What the tap saw, waiting for the main thread. Moves of a held mouse button are many and only the last
/// one matters, so a move replaces a move still waiting; everything else keeps its order.
final class SampleMailbox<Sample> {
    private let lock = NSLock()
    private var pending: [(sample: Sample, isMove: Bool)] = []

    /// Add one; true if the mailbox was empty, which is when the main thread has to be told.
    func post(_ sample: Sample, isMove: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let wasEmpty = pending.isEmpty
        if isMove, let last = pending.last, last.isMove { pending[pending.count - 1] = (sample, true) }
        else { pending.append((sample, isMove)) }
        return wasEmpty
    }

    func drain() -> [Sample] {
        lock.lock(); defer { lock.unlock() }
        let all = pending.map(\.sample)
        pending = []
        return all
    }
}
