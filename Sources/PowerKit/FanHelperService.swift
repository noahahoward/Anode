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

    /// The fan's control MODE, and the reason fan control did nothing at all for
    /// the first several attempts at this feature.
    ///
    /// A target written while the fan is on automatic is simply ignored: the
    /// firmware keeps deciding, and `F<n>Tg` reads back as whatever the firmware
    /// wants rather than what was written. Measured, on a machine that had just
    /// been asked for 7826 rpm on both fans and reported success:
    ///
    ///     F0Tg = 2317 (its own minimum)   F1Tg = 2502   F0md = 0   F1md = 0
    ///
    /// The key is `F<n>md` — LOWERCASE. An earlier probe looked for `F<n>Md`,
    /// the Intel spelling, found nothing, and concluded this machine had no mode
    /// key. It has one; the probe was guessing at four-character names instead of
    /// enumerating them, which is why `--fankeys` now lists every F* key the
    /// machine actually has rather than the six someone thought of.
    ///
    /// nil when the mode cannot be read, which is not the same as "automatic" and
    /// must not be treated as it: a machine whose mode is unreadable is one this
    /// helper should leave alone rather than guess at.
    func readMode(index: Int) -> Double?

    /// Take or hand back the firmware's control of one fan. The value is written
    /// verbatim rather than as a bool, because release restores WHAT WAS THERE —
    /// the same rule the target follows, for the same reason: this project ships
    /// to hardware nobody here has run on, and 0/1 is an assumption about what
    /// the numbers mean, not an observation.
    func writeMode(index: Int, value: Double) -> Bool
}

/// The two values `F<n>md` is known to take on this hardware.
///
/// OBSERVED, and only two of them. Every Mac this project has run on reports 0
/// while the firmware is deciding, and the fan obeys a written target only after
/// 1 is written. That is the whole basis for these names — there is no
/// documentation, and a third value would mean something nobody here has seen.
///
/// `forced` is the ONLY value this project ever writes that it did not first
/// read from the machine. Everything else in the release path restores an
/// observed number; taking control cannot, because "the value that means take
/// control" is not a value the machine will show you until you have taken it.
/// `automatic` is here to be compared against, never written — a release puts
/// back the mode it found, which is usually this and does not have to be.
public enum SMCFanMode {
    public static let automatic: Double = 0
    public static let forced: Double = 1
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
    /// The control mode a taken fan was in before we took it, when it could be
    /// read. Kept for the same reason and released the same way: restoring an
    /// observed value assumes nothing about what the numbers mean.
    private var previousMode: [Int: Double] = [:]

    public init() {}

    public var isEmpty: Bool { taken.isEmpty }
    /// Ascending, so a release writes fans in a fixed order and a test can say
    /// what it expects.
    public var indices: [Int] { taken.sorted() }

    public func wasTaken(_ index: Int) -> Bool { taken.contains(index) }
    public func previousTarget(of index: Int) -> Double? { previous[index] }
    public func previousMode(of index: Int) -> Double? { previousMode[index] }

    /// Record a first write. Ignored for a fan already taken: our own earlier
    /// target must never overwrite the memory of what automatic looked like.
    public mutating func took(_ index: Int,
                              previousTarget: Double?,
                              previousMode mode: Double? = nil) {
        guard !taken.contains(index) else { return }
        taken.insert(index)
        if let previousTarget, previousTarget.isFinite { previous[index] = previousTarget }
        if let mode, mode.isFinite { previousMode[index] = mode }
    }

    public mutating func forgetAll() {
        taken.removeAll()
        previous.removeAll()
        previousMode.removeAll()
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
            let target = hardware.writeTarget(index: i, rpm: restore)

            // Then hand the fan itself back, which is what actually ends our
            // control — a restored target under a still-forced mode is this app
            // holding the fan at the number the firmware happened to want, which
            // looks like a release and is not one.
            //
            // Ordered target-then-mode so the fan is never briefly on automatic
            // while still carrying our speed. The fallback is `automatic`: a fan
            // we forced and whose original mode we never read has to go back to
            // something, and leaving it forced is the one outcome that is
            // certainly wrong.
            let mode = hardware.writeMode(index: i,
                                          value: holdings.previousMode(of: i) ?? SMCFanMode.automatic)
            if target && mode { released += 1 } else { refused += 1 }
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
            let target = hardware.writeTarget(index: i, rpm: noForcedTarget)
            // And the mode, for the same reason as above: a fan left forced is
            // still this project's fan, which is exactly what "an app that pinned
            // my fans has been deleted" needs undone.
            let mode = hardware.writeMode(index: i, value: SMCFanMode.automatic)
            if target && mode { released += 1 } else { refused += 1 }
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

    /// LOWERCASE `md`. `F0Md` does not exist on this machine and `F0md` does —
    /// see `FanHardware.readMode` for how that cost this feature several rounds
    /// of "the write succeeds and nothing happens".
    public func readMode(index: Int) -> Double? {
        smc?.read("F\(index)md")?.value
    }

    public func writeMode(index: Int, value: Double) -> Bool {
        // ui8, unlike every other fan key. Out-of-range is refused here rather
        // than truncated: a mode this code has never seen is not one to coerce
        // into a byte and hope.
        guard value.isFinite, value >= 0, value <= 255,
              value == value.rounded() else { return false }
        return smc?.writeUInt8("F\(index)md", UInt8(value)) ?? false
    }
}

// ── The server ──────────────────────────────────────────────────────────────

/// What a client has sent that is not yet a whole request, and since when.
///
/// The helper never waits on a client: it reads what is there, keeps it here,
/// and acts only on whole lines. The rules a slow client is held to live here,
/// pure, so they can be tested without a socket: an unfinished line has a
/// deadline counted from its FIRST byte — later bytes do not extend it — and no
/// line may be longer than `FanWire.maxLineBytes`.
struct RequestLines {
    private(set) var pending = Data()
    /// When the unfinished line at the front began arriving; nil when there is
    /// none (nothing pending, or a whole line is waiting to be served).
    private(set) var unfinishedSince: Date?

    var hasLine: Bool { pending.contains(0x0A) }
    /// More than a request can be, with no newline in it.
    var tooLong: Bool { !hasLine && pending.count > FanWire.maxLineBytes }

    mutating func append<S: Sequence>(_ bytes: S, at now: Date) where S.Element == UInt8 {
        pending.append(contentsOf: bytes)
        mark(now)
    }

    /// The next whole line, without its newline, or nil if there is none yet.
    mutating func next(at now: Date) -> Data? {
        guard let idx = pending.firstIndex(of: 0x0A) else { return nil }
        let line = Data(pending[pending.startIndex..<idx])
        pending.removeSubrange(pending.startIndex...idx)
        mark(now)
        return line
    }

    /// Has the unfinished line been unfinished for `deadline` or longer?
    func stalled(at now: Date, after deadline: TimeInterval) -> Bool {
        guard let unfinishedSince else { return false }
        return now.timeIntervalSince(unfinishedSince) >= deadline
    }

    mutating func reset() {
        pending.removeAll()
        unfinishedSince = nil
    }

    private mutating func mark(_ now: Date) {
        if pending.isEmpty || hasLine { unfinishedSince = nil }
        else if unfinishedSince == nil { unfinishedSince = now }
    }
}

/// The helper's socket, its access check, and the operations behind it: set fan
/// N to R rpm, release the fans, set the macOS charge limit (20–100%), cut the
/// charger to discharge down to a percentage, and reconnect it.
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
    private var lines = RequestLines()
    private var wakePipe: [Int32] = [-1, -1]

    /// How long a client may take between the first byte of a request and its
    /// newline before it is dropped (which reconnects the charger). The loop
    /// never waits for those bytes — this only bounds how long a connection
    /// that stopped mid-request is kept. A var only so a test can change it.
    var requestLineDeadline: TimeInterval = 5
    /// The most one reply may take to write, in total.
    var replyWriteDeadline: TimeInterval = 2

    /// Did this process create the socket file, and may it therefore delete it?
    ///
    /// A session helper binds its own socket and unlinks it on the way out, so a
    /// stale path never outlives the process. An ON-DEMAND DAEMON MUST NOT: the
    /// socket belongs to launchd, which is still holding it and will use it to
    /// start the next helper. Unlinking it would make this the LAST helper that
    /// ever started — every later connection would find nothing at that path.
    private var ownsSocketPath = true

    /// How long to wait, with nothing connected, no fan held and no discharge
    /// running, before this helper stops. nil for a session helper, which is
    /// stopped by the person who started it and by nothing else.
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

    /// The system's sleep and wake, as the loop is told about them.
    private enum PowerNotice {
        /// Signalled once the loop has acted on it.
        case willSleep(answered: DispatchSemaphore)
        case didWake
        /// The loop did not answer a will-sleep in time, so the sleep watch
        /// wrote the reconnect itself (`noteSystemWillSleep`). The loop owes it
        /// until its OWN read-back shows the charger connected.
        case reconnectOwed
        /// The wall-clock timer for the plan's moment fired. Carries the
        /// arming it belongs to, so one that was already on its way when the
        /// plan was replaced or cancelled is ignored.
        case planDue(generation: Int)
    }

    /// Notices posted from the sleep watch's queue, in the order they came,
    /// for the loop to act on. Behind `stateLock`, beside the stop flag, and
    /// for the same reason.
    private var powerNotices: [PowerNotice] = []
    /// Set once the loop has handed everything back on its way out. A notice
    /// posted after that is answered at once: nothing is left to reconnect.
    private var loopEnded = false

    /// The longest a will-sleep notice waits for the loop before the sleep
    /// watch reconnects the charger itself and macOS is answered, so a stuck
    /// loop can never hold up sleep — nor let it happen with the charger cut.
    ///
    /// Longer than one pass a slow client can hold up. The notice is acted on
    /// at the top of the loop's next pass, and the pass before it may still be
    /// writing a reply to a client that stopped reading — up to
    /// `replyWriteDeadline` (2 s) — before the reconnect's own read-back (about
    /// 0.65 s, `ChargeRelease.Timing.standard`). Equal to the reply deadline,
    /// as it once was, that could overrun it, and the Mac was let sleep with the
    /// charger still cut. So it is at least the reply deadline plus a 3 s
    /// margin, which a test pins. A longer bound costs nothing: a healthy loop
    /// answers in milliseconds, and macOS waits about 30 s for the answer.
    public static let sleepAnswerDeadline: TimeInterval = 6

    /// Between a will-sleep and the next wake. A discharge is refused for the
    /// whole of it. Touched only on the loop thread.
    private(set) var systemAsleep = false

    /// The system would not register this helper for sleep notices, so nothing
    /// would reconnect the charger before the Mac sleeps. While true, every
    /// discharge is refused; limit writes, fan commands and reconnects are not.
    /// Set by the helper's entry when `SystemSleepWatch` fails, before `run()`.
    /// Off by default: a server nobody tells otherwise takes discharges.
    public var sleepNoticesUnavailable = false

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

    /// The charger. nil on a helper built without charge control, which then
    /// refuses the charge commands.
    private let charge: ChargeHardware?

    /// The charger as the sleep watch reaches it when the loop has not
    /// answered in time — never touched by the loop thread. In the helper, a
    /// second `SystemChargeHardware` with its own SMC connection, so a loop
    /// stuck in a call on the first is not in the way and no SMC object is
    /// shared between threads. nil exactly when `charge` is.
    private let chargeWithoutTheLoop: ChargeHardware?

    private let powerEvents: PowerEventScheduler?
    private let wakeTimer: WallClockTimer

    /// The plan this helper holds: a limit to write at a moment, with a wake scheduled for it. One at a time. Only
    /// the loop thread touches it.
    private(set) var chargePlan: ChargePlan?

    /// The percentage a discharge stops at, while this helper holds the charger
    /// cut. nil when it holds no cut.
    ///
    /// Cleared only by a reconnect that READ BACK connected: a failed one keeps
    /// it, so the helper stays up (see `isIdle`) and the watch tries again.
    public private(set) var dischargeTarget: Int?

    /// A reconnect failed and is still owed: this helper made the cut, the
    /// undo of a cut that did not read back could not be read back either, or
    /// the charger still reads cut after the writes. The watch retries it on
    /// every wake whatever the battery says, always writing, and the helper is
    /// not idle — and takes no new discharge — until a read shows it connected.
    private(set) var reconnectOwed = false

    /// How long, and how many failed retries, it takes to stop owing a reconnect for a cut this helper never held and
    /// never read as cut. On a Mac with no adapter-cut key whose SMC answers the key-info call oddly, the undo of a
    /// cut that cannot be confirmed can never be read back either, and without a bound it would keep the helper up and
    /// wake root every 10 s until it died. Both are needed: a few quick failures say nothing (the SMC is a
    /// microcontroller, and the key may come back), and the longer the failures run the less likely there is a cut.
    /// Two minutes and six retries at the watch's 10 s.
    static let unheldRetryLimit = 6
    static let unheldGiveUpAfter: TimeInterval = 120
    /// Failed retries of the reconnect owed now, and when the first was, counted only while no cut was held or seen.
    private var unheldRetries = 0
    private var unheldSince: Date?
    /// This helper has held a cut, or something it read said the charger was cut, or the SMC took a write that cuts it
    /// (`startDischarge`): a reconnect owed after that is never given up, because the charger really may be cut.
    private var everHeldOrSawACut = false
    private var saidGaveUp = false

    /// Values the adapter-cut key has been found holding that Anode never
    /// writes, each already logged once. Loop thread only.
    private var unrecognisedCutValuesSaid: Set<UInt8> = []

    /// How often a discharge looks at the battery. The only periodic wake this
    /// helper ever has, and only while the charger is cut. A var only so a test
    /// can shorten it; set it before `run()`.
    var dischargeWatchInterval: TimeInterval = 10

    /// How hard each charger write is tried and read back. A var only so a test
    /// can skip the pauses.
    var chargeTiming: ChargeRelease.Timing = .standard

    /// The server's clock, for the spacing between cuts. A var only so a test
    /// can move it instead of sleeping; set it before `run()`.
    var now: () -> Date = Date.init

    /// The least time between two attempts to cut the charger. A discharge
    /// asked for sooner is refused with nothing written, so no client can
    /// switch the charger every second, and a cut the SMC keeps refusing is
    /// not retried on every ask. Reconnects are never spaced.
    public static let cutSpacing: TimeInterval = 10

    /// When this helper last tried to cut the charger, whether or not the cut
    /// was taken. Loop thread only.
    private var lastCutAttempt: Date?

    /// `log` is called from the loop thread and, when the loop has not answered
    /// a sleep notice in time, from the sleep watch's: it must be safe on both.
    ///
    /// `sleepCharge` is the charger the sleep watch writes when the loop has
    /// not answered — a separate connection to the same charger. nil uses
    /// `charge` itself, which is right only for a charger safe to call from
    /// two threads (the tests' fake). Ignored without `charge`.
    ///
    /// `powerEvents` is how this helper wakes the Mac for a plan (`scheduleChargeLimit`). nil, which is what every
    /// server gets that is not told otherwise, refuses plans: only the helper's own `main` hands over the real one,
    /// so nothing that builds a server, a test least of all, can schedule a wake by accident. `wakeTimer` is its own
    /// wall-clock timer for the same moment.
    public init(hardware: FanHardware,
                configuration: Configuration,
                log: @escaping (String) -> Void = { _ in },
                charge: ChargeHardware? = nil,
                sleepCharge: ChargeHardware? = nil,
                powerEvents: PowerEventScheduler? = nil,
                wakeTimer: WallClockTimer = DispatchWallClockTimer()) {
        self.hardware = hardware
        self.config = configuration
        self.log = log
        self.charge = charge
        self.chargeWithoutTheLoop = charge == nil ? nil : (sleepCharge ?? charge)
        self.powerEvents = powerEvents
        self.wakeTimer = wakeTimer
    }

    /// Nothing connected, no fan held, the charger not cut, and no reconnect
    /// owed. Only then may an on-demand daemon time out — exiting mid-discharge
    /// would leave the battery draining with nobody watching the floor.
    ///
    /// Nor while a plan is pending: the plan is a wake and a write the helper
    /// has promised, and an on-demand helper that exited would break the
    /// promise without a word. (A plan only lives while its client is
    /// connected, which already keeps the helper up; this says it in its own
    /// right.)
    var isIdle: Bool {
        clientFD < 0 && holdings.isEmpty && dischargeTarget == nil && !reconnectOwed && chargePlan == nil
    }

    /// Reconnect a charger cut that no live helper owns.
    ///
    /// A cut OUTLIVES the process that made it — measured: `kill -9` left
    /// `CHIE` = 08 and the charger disconnected. Only one helper serves the
    /// socket, so a cut found at startup belongs to a helper that died without
    /// its dead man's switch. Run by both `start` paths, before anything is
    /// served. Writes nothing, and says nothing, when the charger reads
    /// connected or the Mac has no such key. Clears ONLY Anode's own value,
    /// 0x08: a value Anode never writes is left alone, and said once
    /// (`reconnectCharger`).
    func clearOrphanedAdapterCut() {
        guard charge != nil else { return }
        let result = reconnectCharger()
        switch result.outcome {
        case .notCut, .noKey, .unrecognised:
            return
        case .reconnected:
            log("cleared an adapter cut nobody owned")
        case .stillCut:
            log("WARNING: found an adapter cut nobody owned and could not clear it — "
              + "\(result.message); retrying every \(Int(dischargeWatchInterval))s")
        case .unconfirmed:
            log("WARNING: the charger's cut key could not be read at startup — "
              + "\(result.message)")
        }
    }

    /// Take away the wakes a helper that was killed left behind. A plan's wake lives in the system's own list, on disk,
    /// under this helper's name, and SIGKILL runs nothing: the plan went with the process, the wake did not, and it
    /// would wake the Mac for nothing at its moment. This helper holds no plan when it starts, so every wake under its
    /// name is one nobody holds. Run by both `start` paths, before anything is served.
    func clearOrphanedWakes() {
        guard let powerEvents else { return }
        let r = powerEvents.cancelAllWakes()
        if r.removed > 0 {
            log("removed \(r.removed) scheduled wake\(r.removed == 1 ? "" : "s") a helper that was killed left behind")
        }
        if r.failed > 0 {
            log("WARNING: \(r.failed) scheduled wake\(r.failed == 1 ? "" : "s") left behind by a helper that was "
              + "killed could not be removed; each wakes the Mac once, and nothing is written")
        }
    }

    /// Bind and listen. Separate from `run()` so a caller — or a test — knows the
    /// socket is ready before anything tries to connect to it.
    public func start() throws {
        clearOrphanedAdapterCut()
        clearOrphanedWakes()
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
        adoptWakePipe(pipeFDs)
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
        clearOrphanedAdapterCut()
        clearOrphanedWakes()
        guard fd >= 0 else { throw Failure.socketFailed("launchd offered no descriptor") }

        // It must be a unix stream socket. That is the whole of what this side
        // can check, and the two things it cannot check are worth naming because
        // each one has already been coded as a refusal that broke the daemon.
        //
        // NOT "and it must be listening": macOS has no way to ask that about a
        // unix socket. `SO_ACCEPTCONN` fails with ENOPROTOOPT on AF_UNIX both
        // before and after `listen()` — measured, not assumed, and an earlier
        // draft of this check used it and rejected every socket launchd offered.
        //
        // NOT "and it must be bound to `config.socketPath`" either, for the same
        // reason with a different mechanism. LAUNCHD DOES NOT BIND THE SOCKET AT
        // `SockPathName`. It binds one inside a private directory of its own and
        // names it after the SOCKET KEY, so `getsockname` on the descriptor it
        // hands over reads
        //
        //     /var/run/com.apple.launchd.<random>/FanControl
        //
        // and never /var/run/anode-fan.sock — measured on macOS 27 with a
        // throwaway LaunchAgent, for a `SockPathName` both under a symlinked
        // directory and not. A draft of this check compared the two and threw,
        // so every helper launchd started exited(1) about 20 ms in, before it
        // could log anything, and the app got a connection that was accepted by
        // launchd and then answered by nobody. That is the bug this comment is
        // standing in the way of a third time.
        //
        // What replaces it is not a weaker version of the same check: there is
        // no path here to compare against. `launch_activate_socket` is keyed by
        // the socket NAME out of our own job's plist, and being handed the
        // descriptor for that key is the identity guarantee — the path is
        // launchd's private business, and asserting anything about its shape
        // would only re-break this the next time Apple changes it.
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

        var pipeFDs: [Int32] = [-1, -1]
        guard pipe(&pipeFDs) == 0 else {
            // The socket is launchd's; it is not ours to close or unlink on the
            // way out of a failure.
            throw Failure.socketFailed(String(cString: strerror(errno)))
        }
        adoptWakePipe(pipeFDs)
        listenFD = fd
        ownsSocketPath = false
        // The bound path is logged rather than checked. It is the one piece of
        // evidence that says which descriptor was actually adopted, and the
        // reason it is worth a line is that a wrong one is otherwise silent.
        log("serving launchd's socket for uid \(config.ownerUID) — clients reach it "
          + "at \(config.socketPath), launchd holds it as \(boundPath)")
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
    ///
    /// THE ONE EXCEPTION TO "NEVER WOKEN" IS A DISCHARGE. While the charger is
    /// cut the loop wakes every `dischargeWatchInterval` to look at the battery,
    /// because the floor has to hold whether or not the app is there to ask.
    /// It also never times out while discharging (`isIdle`).
    ///
    /// A SLEEP OR WAKE NOTICE wakes it the way a stop signal does — a byte on
    /// the wake pipe — and is acted on before any request line is served, so a
    /// discharge asked for after the Mac said it is going to sleep is refused.
    ///
    /// NOTHING A CLIENT DOES CAN HOLD THIS THREAD. The client socket is
    /// non-blocking: a readable client gets one `read`, whole lines are served
    /// one per pass, a half-sent line waits in `lines` (and is dropped after
    /// `requestLineDeadline`), and a reply gets `replyWriteDeadline` in total.
    /// So every pass reaches the floor check and the stop check whatever the
    /// client is doing — slow, half-sent, or silent.
    public func run() {
        var idleSince: Date? = Date()
        while !stopping {
            // A whole line already buffered is served before more is read: the
            // client is left out of the poll, so a flood waits in ITS socket
            // buffer instead of growing ours, and the poll does not wait.
            let lineWaiting = clientFD >= 0 && lines.hasLine
            let pollsClient = clientFD >= 0 && !lineWaiting
            var fds = [pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: wakePipe[0], events: Int16(POLLIN), revents: 0)]
            if pollsClient {
                fds.append(pollfd(fd: clientFD, events: Int16(POLLIN), revents: 0))
            }

            let idling = isIdle
            if !idling { idleSince = nil }
            else if idleSince == nil { idleSince = Date() }

            var timeout: Int32 = -1
            if let idleExit, let idleSince, idling {
                let left = idleExit - Date().timeIntervalSince(idleSince)
                if left <= 0 {
                    log("idle for \(Int(idleExit))s with no fan held and no discharge — stopping. "
                      + "launchd starts a new helper when the app next connects.")
                    break
                }
                timeout = Self.milliseconds(left)
            }
            if dischargeTarget != nil || reconnectOwed {
                // Never idle while discharging or owing a reconnect.
                timeout = Self.sooner(timeout, Self.milliseconds(dischargeWatchInterval))
            }
            if let since = lines.unfinishedSince {
                let left = requestLineDeadline - Date().timeIntervalSince(since)
                timeout = Self.sooner(timeout, Self.milliseconds(left))
            }
            if lineWaiting { timeout = 0 }

            guard poll(&fds, nfds_t(fds.count), timeout) >= 0 || errno == EINTR else { break }
            if stopping { break }

            if fds[1].revents & Int16(POLLIN) != 0 {
                var scratch = [UInt8](repeating: 0, count: 16)
                _ = read(wakePipe[0], &scratch, scratch.count)
            }
            if pollsClient, fds[2].revents != 0 { readFromClient() }
            // After the read and before the serve: a line read in this pass was
            // sent after any notice already posted, and must see it.
            actOnPowerNotices()
            serveOneLine()
            dropAClientThatStalled()
            if fds[0].revents & Int16(POLLIN) != 0 { acceptOne() }
            // On every wake, not only the timed ones: a busy client must not be
            // able to starve the floor check.
            watchDischarge()
        }
        shutdownSocket()
    }

    private static func milliseconds(_ seconds: TimeInterval) -> Int32 {
        Int32((max(0, seconds) * 1000).rounded(.up))
    }

    /// The earlier of two poll timeouts, where -1 is "no timeout".
    private static func sooner(_ a: Int32, _ b: Int32) -> Int32 {
        a < 0 ? b : min(a, b)
    }

    /// Reconnect the charger if a reconnect is owed, or if the discharge has
    /// reached its floor, the battery cannot be read, or the cable is known to
    /// be out. Does nothing when no cut is held and nothing is owed.
    func watchDischarge() {
        guard let charge else { return }
        if reconnectOwed {
            let result = reconnectCharger()
            log(result.ok ? "\(result.message) (on a retry)"
                          : "\(result.message) — retrying in \(Int(dischargeWatchInterval))s")
            if !result.ok { countAFailedRetry() }
            return
        }
        guard let target = dischargeTarget else { return }
        let percent = charge.batteryPercent()
        guard DischargeWatch.shouldRestore(target: target,
                                           percent: percent,
                                           onAC: charge.onAC()) else { return }
        let why = "discharge to \(target)% ended, battery "
            + (percent.map { "\($0)%" } ?? "unreadable")
        log("\(reconnectCharger().message) (\(why))")
    }

    /// Wake the loop and let it unwind. Safe to call from another thread — it
    /// only writes one byte to a pipe.
    public func stop() {
        stopping = true
        wakeLoop()
    }

    /// The one way another thread gets the loop's attention: a byte on the wake
    /// pipe. A stop signal and a sleep notice both come through here.
    ///
    /// Under `stateLock`, as is every change to the pipe, so a byte can never go
    /// to a descriptor `shutdownSocket` has closed and something else has since
    /// been given. The write end is non-blocking: a full pipe already wakes the
    /// loop, and the byte is not needed.
    private func wakeLoop() {
        stateLock.lock(); defer { stateLock.unlock() }
        guard wakePipe[1] >= 0 else { return }
        var byte: UInt8 = 1
        _ = write(wakePipe[1], &byte, 1)
    }

    private func adoptWakePipe(_ fds: [Int32]) {
        _ = fcntl(fds[1], F_SETFL, fcntl(fds[1], F_GETFL) | O_NONBLOCK)
        stateLock.lock(); wakePipe = fds; stateLock.unlock()
    }

    // ── Sleep ───────────────────────────────────────────────────────────────

    /// The Mac is about to sleep: tell the loop, and wait until it has acted —
    /// at most `timeout`. True when the loop answered in time.
    ///
    /// For the sleep watch's queue, or any thread but the loop's. Nothing in
    /// this process runs while the Mac sleeps, so the charger must be
    /// reconnected before macOS is answered; and macOS must be answered whatever
    /// the loop is doing, so the wait is bounded. When the loop has not
    /// answered by then, the charger is reconnected FROM HERE before this
    /// returns (`reconnectWithoutTheLoop`): a loop stuck in a limit write must
    /// not let the Mac sleep with the charger cut.
    @discardableResult
    public func noteSystemWillSleep(timeout: TimeInterval = sleepAnswerDeadline) -> Bool {
        // One semaphore per notice: a loop that answers one late must never
        // bank a signal that lets the NEXT sleep through unanswered.
        let answered = DispatchSemaphore(value: 0)
        stateLock.lock()
        if loopEnded { stateLock.unlock(); return true }
        powerNotices.append(.willSleep(answered: answered))
        stateLock.unlock()
        wakeLoop()
        if answered.wait(timeout: .now() + timeout) == .success { return true }
        reconnectWithoutTheLoop(waited: timeout)
        return false
    }

    /// The loop has not answered a will-sleep: reconnect the charger from the
    /// sleep watch's thread, before macOS is answered.
    ///
    /// SELF-CONTAINED. It needs nothing from the loop thread and reads none of
    /// its books — whether a discharge is held is the loop's to know, and the
    /// loop is stuck — so it writes 0x00 whatever the key reads, and judges
    /// that by reading it back (`ChargeRelease.reconnect(alwaysWrite:)`),
    /// through `chargeWithoutTheLoop`, a connection the loop never uses. 0x00
    /// is the one write that can never leave the charger cut.
    ///
    /// It changes no server state. The only thing it hands the loop goes
    /// through `powerNotices`, under `stateLock`, as every notice does: the
    /// reconnect is owed, so the loop writes it again on its next pass and
    /// clears its books only on its own confirmed read-back. Not on a Mac the
    /// SMC says has no such key: a reconnect that can never land would
    /// otherwise keep an on-demand helper up for ever.
    private func reconnectWithoutTheLoop(waited: TimeInterval) {
        guard let charger = chargeWithoutTheLoop else { return }
        let result = ChargeRelease.reconnect(charger, alwaysWrite: true, timing: chargeTiming)
        var handedOver = false
        if result.outcome != .noKey {
            stateLock.lock()
            // A loop that has ended has already reconnected on its way out.
            if !loopEnded {
                powerNotices.append(.reconnectOwed)
                handedOver = true
            }
            stateLock.unlock()
        }
        if handedOver { wakeLoop() }
        // Reconnect first, then log.
        let why = "the loop did not answer a sleep notice within "
            + String(format: "%g", waited) + "s"
        if result.ok {
            log("WARNING: \(why) — the sleep watch reconnected the charger itself "
              + "(\(result.message)) before letting sleep through")
        } else {
            log("WARNING: \(why) — the sleep watch's own reconnect failed (\(result.message)); "
              + "sleep was let through, and the loop retries it once it can")
        }
    }

    /// The Mac has woken. For any thread but the loop's; does not wait.
    public func noteSystemDidWake() {
        stateLock.lock()
        powerNotices.append(.didWake)
        stateLock.unlock()
        wakeLoop()
    }

    /// Act on every posted notice, oldest first: a sleep then a wake the loop
    /// was too busy to see must leave the helper awake, not asleep.
    func actOnPowerNotices() {
        stateLock.lock()
        let notices = powerNotices
        powerNotices.removeAll()
        stateLock.unlock()
        for notice in notices {
            switch notice {
            case .willSleep(let answered):
                systemWillSleep()
                answered.signal()
            case .didWake:
                systemDidWake()
            case .reconnectOwed:
                owesTheSleepWatchsReconnect()
            case .planDue(let generation):
                if generation == planGeneration { planTimerFired() }
            }
        }
    }

    /// The sleep watch reconnected the charger without the loop. LOOP THREAD
    /// ONLY. Its write is not this thread's read-back, so the reconnect is owed
    /// — and made at once, before this pass serves anything: a read-back that
    /// shows connected clears the target and the debt, as every reconnect
    /// does; a failure stays owed and the watch retries it on every pass.
    private func owesTheSleepWatchsReconnect() {
        if dischargeTarget != nil { everHeldOrSawACut = true }
        reconnectOwed = true
        let result = reconnectCharger()
        if result.ok {
            log("\(result.message) (after the sleep watch's own reconnect)")
        } else {
            log("WARNING: \(result.message) after the sleep watch's own reconnect — "
              + "retrying every \(Int(dischargeWatchInterval))s")
        }
    }

    /// On the way out, after `release()` has reconnected the charger: answer
    /// every sleep notice still waiting, and any posted later, at once.
    private func answerPowerNoticesOnTheWayOut() {
        stateLock.lock()
        let notices = powerNotices
        powerNotices.removeAll()
        loopEnded = true
        stateLock.unlock()
        for case .willSleep(let answered) in notices { answered.signal() }
    }

    /// Reconnect the charger before the Mac sleeps, and refuse to cut it again
    /// until it wakes. LOOP THREAD ONLY: the watch reaches it through
    /// `noteSystemWillSleep`.
    ///
    /// Through the same routine `stopDischarge` uses, and with the same books: a
    /// reconnect that read back connected clears the target; one that failed is
    /// still owed and is retried by the watch after wake. Reconnect first, then
    /// log. A sleep with nothing cut writes nothing and says nothing.
    func systemWillSleep() {
        systemAsleep = true
        guard dischargeTarget != nil || reconnectOwed else { return }
        let result = reconnectCharger()
        if result.ok {
            log("reconnected the charger before sleep")
        } else {
            log("WARNING: \(result.message) before sleep — retrying after wake, "
              + "every \(Int(dischargeWatchInterval))s")
        }
    }

    /// The Mac is awake. LOOP THREAD ONLY. A discharge is NOT resumed: the app
    /// decides again, and asks.
    ///
    /// Every wake is a look at the plan: if its moment has come the limit is
    /// written now, whichever of this notice and the plan's own timer got here
    /// first. A wake before the moment leaves the plan where it is.
    func systemDidWake() {
        systemAsleep = false
        firePlanIfDue()
    }

    // ── Connections ─────────────────────────────────────────────────────────

    private func acceptOne() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        // configure first, for SO_NOSIGPIPE; then non-blocking, so no read or
        // write on this client can hold the loop (see `run`).
        FanSocketIO.configure(fd, timeout: 5)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

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
            refuse(fd, "another Anode window already has fan control")
            return
        }
        clientFD = fd
        lines.reset()
        log("client connected")
    }

    private func refuse(_ fd: Int32, _ why: String) {
        // Say no out loud. A connection that is simply closed leaves the app
        // showing "the helper stopped answering", which is the same message a
        // crash produces and tells the user nothing about what to do.
        if let data = try? FanWire.encode(FanReply(ok: false, message: why)) {
            _ = FanSocketIO.writeAll(fd, data, within: replyWriteDeadline)
        }
        close(fd)
    }

    /// One `read` of whatever the client has sent — never a wait for more.
    private func readFromClient() {
        var chunk = [UInt8](repeating: 0, count: 1024)
        let n = read(clientFD, &chunk, chunk.count)
        if n > 0 {
            lines.append(chunk[0..<n], at: Date())
            if lines.tooLong {
                dropClient(reason: "a request longer than \(FanWire.maxLineBytes) bytes")
            }
            return
        }
        if n < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return }
        dropClient(reason: n == 0 ? "the client disconnected"
                                  : "the client's socket failed: \(String(cString: strerror(errno)))")
    }

    /// Serve at most ONE whole line, so a client with many queued requests
    /// still lets the loop reach the floor check between each of them.
    private func serveOneLine() {
        guard clientFD >= 0, let line = lines.next(at: Date()) else { return }
        let request: FanRequest
        do {
            request = try FanWire.decode(FanRequest.self, from: line)
        } catch {
            dropClient(reason: "malformed request (\(error))")
            return
        }
        let reply = handle(request)
        if let data = try? FanWire.encode(reply),
           !FanSocketIO.writeAll(clientFD, data, within: replyWriteDeadline) {
            dropClient(reason: "the client stopped reading")
        }
    }

    /// A client that began a request and has not finished it is dropped once
    /// `requestLineDeadline` has passed since its first byte, however slowly it
    /// keeps dripping the rest.
    private func dropAClientThatStalled() {
        guard clientFD >= 0, lines.stalled(at: Date(), after: requestLineDeadline) else { return }
        dropClient(reason: "it began a request and did not finish it within "
                         + "\(Int(requestLineDeadline.rounded(.up)))s")
    }

    /// The client went away — quit, crashed, or was killed. Hand the fans back.
    ///
    /// This is the dead man's switch, and it is the reason the app closes its
    /// socket on quit rather than sending a polite goodbye: the crash path and
    /// the ordinary-quit path are then the same path, so the one that matters
    /// gets exercised every day instead of never.
    ///
    /// RELEASE BEFORE THE FIRST LOG LINE. A log line is a write to whatever
    /// stderr is, and the charger must be reconnected before anything that
    /// could fail; `HelperLog` cannot end the process, and this order means it
    /// would not matter if something someday could.
    private func dropClient(reason: String) {
        guard clientFD >= 0 else { return }
        close(clientFD)
        clientFD = -1
        lines.reset()
        let reply = release()
        // The plan lives on the connection, like a discharge: whoever asked for it is gone, so nothing is written for
        // it and the Mac is not woken for it.
        dropPlan(because: "the client went away")
        log("client gone (\(reason))")
        log(reply.message)
    }

    private func shutdownSocket() {
        // Order matters: release while the SMC is still ours to talk to, then
        // take the socket away so nothing can reconnect mid-teardown.
        if clientFD >= 0 { dropClient(reason: "the helper is stopping") }
        else { log(release().message) }
        // Whatever stopped the helper (a signal, an uninstall, its own exit), no wake is left behind and nothing is
        // written afterwards.
        dropPlan(because: "the helper is stopping")
        answerPowerNoticesOnTheWayOut()
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        // Only if we made it. launchd's socket outlives this process on purpose:
        // it is what the next connection arrives on, and removing it would make
        // this the last helper that ever started.
        if ownsSocketPath { unlink(config.socketPath) }
        stateLock.lock()
        for fd in wakePipe where fd >= 0 { close(fd) }
        wakePipe = [-1, -1]
        stateLock.unlock()
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
        case .command(.setChargeLimit(let percent)):
            return setChargeLimit(percent)
        case .command(.discharge(let target)):
            return discharge(to: target)
        case .command(.stopDischarge):
            return stopDischarge()
        case .command(.scheduleChargeLimit(let limit, let at)):
            return scheduleChargeLimit(limit, at: at)
        case .command(.cancelScheduledChargeLimit):
            return cancelScheduledChargeLimit()
        }
    }

    // ── The charger ─────────────────────────────────────────────────────────

    /// The range the helper accepts for macOS's charge limit. The app's own
    /// range may be narrower; this is the boundary root enforces.
    static let chargeLimitRange = 20...100
    /// The range a discharge target may name. `DischargeWatch.floor` still
    /// applies on top: nothing discharges below 10%.
    static let dischargeTargetRange = 10...100

    private func setChargeLimit(_ percent: Int) -> FanReply {
        guard let charge else {
            return FanReply(ok: false, message: ChargeRefusal.noChargeControl)
        }
        guard Self.chargeLimitRange.contains(percent) else {
            return FanReply(ok: false, message: "refused: a charge limit must be "
                          + "\(Self.chargeLimitRange.lowerBound)–\(Self.chargeLimitRange.upperBound)%")
        }
        // Not held, and not undone on disconnect: the limit is macOS's own
        // setting and stays where the user put it.
        guard charge.writeChargeLimit(percent) else {
            log("could not write the charge limit \(percent)%")
            return FanReply(ok: false, message: "macOS did not take the charge limit")
        }
        log("set the macOS charge limit to \(percent)%")
        return FanReply(ok: true, message: "charge limit set to \(percent)%")
    }

    /// Every refusal here is a `ChargeRefusal` constant, word for word: the app
    /// compares against the same ones.
    private func discharge(to target: Int) -> FanReply {
        guard let charge else {
            return FanReply(ok: false, message: ChargeRefusal.noChargeControl)
        }
        // No sleep notices, so nothing would reconnect the charger before the
        // Mac sleeps. Refused for this helper's whole life; it will not change.
        guard !sleepNoticesUnavailable else {
            return FanReply(ok: false, message: ChargeRefusal.noSleepNotices)
        }
        // Nothing here runs while the Mac sleeps, so nothing would watch the
        // floor. Refused until the wake; the reconnect is never refused.
        guard !systemAsleep else {
            return FanReply(ok: false, message: ChargeRefusal.goingToSleep)
        }
        // A reconnect known to be failing is not hidden behind a new cut. On a
        // charger stuck at 0x08, even a refused cut reads back as one, and
        // taking it would clear the debt and answer "discharging". Refused,
        // with nothing written, until the watch reads the charger connected.
        guard !reconnectOwed else {
            return FanReply(ok: false, message: ChargeRefusal.reconnectOwed)
        }
        guard Self.dischargeTargetRange.contains(target) else {
            return FanReply(ok: false, message: ChargeRefusal.targetOutOfRange)
        }
        // The same test the watch uses, asked before cutting: a discharge that
        // would end on its first check is not started at all.
        let percent = charge.batteryPercent()
        let ac = charge.onAC()
        guard !DischargeWatch.shouldRestore(target: target, percent: percent, onAC: ac) else {
            let why: String
            if percent == nil { why = ChargeRefusal.batteryUnreadable }
            else if ac == false { why = ChargeRefusal.noCharger }
            else { why = ChargeRefusal.atOrBelow(max(target, DischargeWatch.floor)) }
            return FanReply(ok: false, message: why)
        }
        // Last before the write, so every lasting reason above is the one a
        // client hears. A clock set back reads as long ago, not as a refusal
        // until it catches up.
        let attempt = now()
        if let last = lastCutAttempt {
            let since = attempt.timeIntervalSince(last)
            guard since < 0 || since >= Self.cutSpacing else {
                return FanReply(ok: false, message: ChargeRefusal.switchedRecently)
            }
        }
        lastCutAttempt = attempt
        // Judged by the read-back alone: the write's own answer is logged, not
        // trusted. A cut that cannot be confirmed is undone at once — with a
        // write, whatever the key reads now, because a read straight after the
        // cut may not show it yet.
        // A write the SMC took may have cut the charger, whether or not it can be read back (a key that cannot be
        // read, a read that came too early): from the write on, a reconnect owed is never given up. A write the SMC
        // refuses, as a Mac with no such key refuses every one, cut nothing, and the bound on its undo stands.
        let cut = ChargeRelease.cut(charge, timing: chargeTiming, taken: { [self] in everHeldOrSawACut = true })
        guard cut.isCut else {
            let undo = reconnectCharger(alwaysWrite: true)
            let why = cut == .refused ? ChargeRefusal.cutRefused : ChargeRefusal.cutNotKept
            log("\(why); \(undo.message)")
            return FanReply(ok: false, message: undo.ok ? why : "\(why); \(undo.message)")
        }
        if cut == .cutAlthoughRefused {
            log("the SMC answered the cut with an error and the charger reads cut — "
              + "going by the read-back")
        }
        dischargeTarget = target
        reconnectOwed = false
        everHeldOrSawACut = true
        log("cut the charger: discharging to \(target)% from \(percent.map { "\($0)%" } ?? "?")")
        return FanReply(ok: true, message: "discharging to \(target)%")
    }

    /// How far ahead a plan may be: the app's 12 hour window and an hour over for a clock that moved.
    public static let chargePlanReach: TimeInterval = 13 * 3600

    /// How close to the moment a wake notice or a timer counts as the moment. The system's wake lands within a second
    /// of what it was asked for, either side; a limit raised a few seconds early costs nothing, and one missed because
    /// the notice came a second before the moment would cost the whole night.
    public static let chargePlanSlack: TimeInterval = 5

    /// Arm counter for the plan's own timer. Loop thread only.
    private var planGeneration = 0

    private static let logTime: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Plan: at `at`, set macOS's charge limit to `limit`, with the Mac woken for it. See `FanCommand`.
    private func scheduleChargeLimit(_ limit: Int, at: Date) -> FanReply {
        guard charge != nil else {
            return FanReply(ok: false, message: ChargeRefusal.noChargeControl)
        }
        guard let powerEvents else {
            return FanReply(ok: false, message: ChargeRefusal.cannotWake)
        }
        guard Self.chargeLimitRange.contains(limit) else {
            return FanReply(ok: false, message: "refused: a charge limit must be "
                          + "\(Self.chargeLimitRange.lowerBound)–\(Self.chargeLimitRange.upperBound)%")
        }
        // A moment that is gone cannot be woken for, and one that is days off is a plan nobody should be holding a
        // root process up for. (NaN is not after now.)
        let ahead = at.timeIntervalSince(now())
        guard ahead > 0 else {
            return FanReply(ok: false, message: ChargeRefusal.planNotInTheFuture)
        }
        guard ahead <= Self.chargePlanReach else {
            return FanReply(ok: false, message: ChargeRefusal.planTooFarAway)
        }
        let when = Self.logTime.string(from: at)
        // The system keeps whole seconds, so the wake is at the next one: never before the moment.
        let wakeAt = Date(timeIntervalSince1970: at.timeIntervalSince1970.rounded(.up))

        if var plan = chargePlan, plan.wakeAt == wakeAt {
            // The same wake again (the app says its plan before every sleep): nothing to schedule twice.
            plan.limit = limit
            plan.at = at
            chargePlan = plan
            armPlanTimer(for: plan)
            log("kept the plan: set the macOS charge limit to \(limit)% at \(when), with a wake at that time")
            return FanReply(ok: true, message: "charge limit \(limit)% planned for \(when)")
        }
        guard powerEvents.scheduleWake(at: wakeAt) else {
            log("the Mac would not take a wake for \(when); no plan was made")
            return FanReply(ok: false, message: ChargeRefusal.wakeNotScheduled)
        }
        // Replaced: the old plan's wake goes now that the new one is in. (Before it, a wake the system refused
        // would have left no plan at all.)
        if let old = chargePlan {
            if !powerEvents.cancelWake(at: old.wakeAt) {
                log("WARNING: could not cancel the wake for the plan this one replaces; it will wake the Mac once, "
                  + "and write nothing")
            }
        }
        let plan = ChargePlan(limit: limit, at: at, wakeAt: wakeAt)
        chargePlan = plan
        planTries = 0
        planRetryAt = nil
        armPlanTimer(for: plan)
        log("planned: set the macOS charge limit to \(limit)% at \(when), with a wake at that time")
        return FanReply(ok: true, message: "charge limit \(limit)% planned for \(when)")
    }

    /// Drop the plan and its wake, writing nothing. Nothing planned is not a failure.
    private func cancelScheduledChargeLimit() -> FanReply {
        guard chargePlan != nil else {
            return FanReply(ok: true, message: "no charge limit was planned")
        }
        let clean = dropPlan(because: "the app cancelled it")
        return FanReply(ok: true, message: clean
            ? "plan cancelled"
            : "plan cancelled; its wake could not be removed and will wake the Mac once, writing nothing")
    }

    /// Forget the plan: the timer stopped, the wake taken away, nothing written. False when the wake could not be
    /// taken away (it then wakes the Mac once, with nothing to do). Does nothing, and says nothing, when there is no
    /// plan. LOOP THREAD ONLY.
    @discardableResult
    private func dropPlan(because why: String) -> Bool {
        guard let plan = chargePlan else { return true }
        chargePlan = nil
        planTries = 0
        planRetryAt = nil
        planGeneration += 1
        wakeTimer.disarm()
        let removed = powerEvents?.cancelWake(at: plan.wakeAt) ?? true
        log("dropped the plan to set the macOS charge limit to \(plan.limit)% at \(Self.logTime.string(from: plan.at)) "
          + "(\(why)); nothing was written, and its wake is cancelled")
        if !removed {
            log("WARNING: the wake for that plan could not be cancelled; it will wake the Mac once and do nothing")
        }
        return removed
    }

    private func armPlanTimer(for plan: ChargePlan) {
        planGeneration += 1
        let generation = planGeneration
        wakeTimer.arm(at: plan.at) { [weak self] in self?.postPlanDue(generation) }
    }

    /// From the timer's queue: hand the news to the loop, the way a sleep notice is, and write nothing here.
    private func postPlanDue(_ generation: Int) {
        stateLock.lock()
        powerNotices.append(.planDue(generation: generation))
        stateLock.unlock()
        wakeLoop()
    }

    /// The plan's timer fired, on the loop. At the moment, write; before it (the clock moved, or the timer was early),
    /// wait for the moment again.
    private func planTimerFired() {
        guard let plan = chargePlan else { return }
        if let retry = planRetryAt, now() < retry {
            // A try is waiting for its time (the timer was early, or the clock moved).
            planGeneration += 1
            let generation = planGeneration
            wakeTimer.arm(at: retry) { [weak self] in self?.postPlanDue(generation) }
        } else if now() >= plan.at.addingTimeInterval(-Self.chargePlanSlack) {
            writeThePlannedLimit(plan)
        } else {
            armPlanTimer(for: plan)
        }
    }

    /// A wake notice, or any pass of the loop that asks: write the plan's limit if its moment has come.
    func firePlanIfDue() {
        guard let plan = chargePlan, now() >= plan.at.addingTimeInterval(-Self.chargePlanSlack) else { return }
        // Not before the next try is due: every wake and every pass of the loop asks, and the tries are for the timer.
        if let retry = planRetryAt, now() < retry { return }
        writeThePlannedLimit(plan)
    }

    /// How many times the plan's limit is tried at its moment, and how long apart. A battery that cannot be read, or a
    /// write the SMC refuses, right at the wake is no reason to give up the night: it is tried again a few seconds on,
    /// with the plan and its wake kept, until a try goes or the tries run out.
    public static let chargePlanTries = 5
    public static let chargePlanTryGap: TimeInterval = 3
    /// The tries made at this plan's moment, and when the next may be made (nil when none is waiting). Loop thread only.
    private var planTries = 0
    private var planRetryAt: Date?

    /// The moment has come: with a charger on the cable, write the limit through the one routine every limit goes
    /// through, and the plan and its wake are done with. No charger on the cable ends it at once (a charger pulled while
    /// the Mac slept ended what the plan was for). A battery that cannot be read, or a write that fails, is tried again
    /// (`chargePlanTries`, `chargePlanTryGap`, on the plan's own wall-clock timer, never a loop that polls) and ends the
    /// plan with a warning only when the tries have run out.
    private func writeThePlannedLimit(_ plan: ChargePlan) {
        planTries += 1
        let failure: String
        switch charge?.onAC() {
        case false?:
            log("the planned moment has come, and no charger is on the cable: the macOS charge limit was not changed")
            return endPlan(plan)
        case true?:
            if charge?.writeChargeLimit(plan.limit) == true {
                log("the planned moment has come: set the macOS charge limit to \(plan.limit)%")
                return endPlan(plan)
            }
            failure = "the macOS charge limit could not be set to \(plan.limit)%"
        default:
            failure = "the battery cannot be read, so it is not known whether a charger is on the cable"
        }
        guard planTries < Self.chargePlanTries else {
            log("WARNING: the planned moment came, and after \(planTries) tries \(failure)")
            return endPlan(plan)
        }
        let again = now().addingTimeInterval(Self.chargePlanTryGap)
        planRetryAt = again
        log("the planned moment has come, and \(failure) (try \(planTries) of \(Self.chargePlanTries)); trying again in "
            + "\(Int(Self.chargePlanTryGap)) s")
        planGeneration += 1
        let generation = planGeneration
        wakeTimer.arm(at: again) { [weak self] in self?.postPlanDue(generation) }
    }

    /// The plan is done with, whichever way it went: the timer, the tries and the wake go with it.
    private func endPlan(_ plan: ChargePlan) {
        chargePlan = nil
        planTries = 0
        planRetryAt = nil
        planGeneration += 1
        wakeTimer.disarm()
        if powerEvents?.cancelWake(at: plan.wakeAt) == false {
            log("WARNING: the wake for the plan could not be cancelled; it has done its work and wakes the Mac no more "
              + "than the once")
        }
    }

    private func stopDischarge() -> FanReply {
        guard charge != nil else {
            return FanReply(ok: false, message: ChargeRefusal.noChargeControl)
        }
        // Asked to reconnect, it reconnects — including a cut it does not
        // remember making, when the key reads 0x08, the value Anode writes.
        // Reconnecting cannot hurt; refusing to could. A charger that reads
        // connected is not written at all, and nor is a value Anode never
        // writes.
        let result = reconnectCharger()
        switch result.outcome {
        case .notCut, .noKey, .unrecognised: break
        default: log("\(result.message) (asked to stop)")
        }
        return FanReply(ok: result.ok, message: result.message)
    }

    /// Reconnect the charger through the one verified routine and keep this
    /// helper's books: the target is cleared only by a reconnect that READ BACK
    /// connected. A failure keeps the target and owes the reconnect — when this
    /// helper holds the cut or already owed it, when the reconnect was the
    /// always-written undo of a cut that did not read back, or when the charger
    /// plainly still reads cut — so the helper stays up (`isIdle`) and the
    /// watch retries it on every pass.
    ///
    /// While a cut is held or a reconnect owed, the write is ALWAYS made and
    /// "no such key" is never the answer (`ChargeRelease.reconnect(holding:)`):
    /// the cut read back, so the key is there, whatever one failed read says.
    @discardableResult
    private func reconnectCharger(alwaysWrite: Bool = false) -> ChargeRelease.Result {
        guard let charge else { return ChargeRelease.Result(.noKey, writes: 0) }
        let holding = dischargeTarget != nil || reconnectOwed
        let result = ChargeRelease.reconnect(charge, alwaysWrite: alwaysWrite,
                                             holding: holding, timing: chargeTiming)
        // Said once per value for the helper's life, not on every stop the app
        // sends: it is a fact about the Mac, and nothing here changes it.
        if case .unrecognised(let value) = result.outcome,
           unrecognisedCutValuesSaid.insert(value).inserted {
            log(result.message)
        }
        if result.outcome == .stillCut { everHeldOrSawACut = true }
        if result.ok {
            dischargeTarget = nil
            reconnectOwed = false
            unheldRetries = 0
            unheldSince = nil
        } else if holding || alwaysWrite || result.outcome == .stillCut {
            if !reconnectOwed {
                unheldRetries = 0
                unheldSince = nil
            }
            reconnectOwed = true
        }
        return result
    }

    /// A retry of the owed reconnect failed. When no cut was ever held or read as cut, enough failures over enough time
    /// stop the debt (`unheldRetryLimit`, `unheldGiveUpAfter`), and that is said once. Not without one last read of the
    /// key: a charger that reads cut now is one, whatever came before. LOOP THREAD ONLY (the watch).
    private func countAFailedRetry() {
        guard reconnectOwed, dischargeTarget == nil, !everHeldOrSawACut else { return }
        let at = now()
        unheldRetries += 1
        let since = unheldSince ?? at
        unheldSince = since
        guard unheldRetries >= Self.unheldRetryLimit, at.timeIntervalSince(since) >= Self.unheldGiveUpAfter else {
            return
        }
        if charge?.adapterCutValue() == AdapterCutKey.cut {
            everHeldOrSawACut = true
            return
        }
        reconnectOwed = false
        unheldRetries = 0
        unheldSince = nil
        guard !saidGaveUp else { return }
        saidGaveUp = true
        log("gave up reconnecting a charger this helper never saw cut: the adapter-cut key could not be read back "
            + "after \(Self.unheldRetryLimit) retries over \(Int(Self.unheldGiveUpAfter)) s, so this Mac probably "
            + "has no such key")
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
            let alreadyHeld = holdings.wasTaken(target.index)
            let before = alreadyHeld ? nil : hardware.readTarget(index: target.index)
            let beforeMode = alreadyHeld ? nil : hardware.readMode(index: target.index)

            // TAKE THE MODE FIRST, or the target is ignored. This is the step
            // whose absence made fan control appear to work and do nothing: the
            // write is accepted, the reply says "set to 7826 rpm", and the
            // firmware goes on running its own number because the fan is still
            // on automatic. See `FanHardware.readMode`.
            //
            // Only on the first write per fan. Re-asserting it on every drag
            // would overwrite nothing useful and give the firmware more chances
            // to disagree mid-gesture.
            if !alreadyHeld, let beforeMode, beforeMode == SMCFanMode.automatic {
                guard hardware.writeMode(index: target.index, value: SMCFanMode.forced) else {
                    return FanReply(ok: false,
                                    message: "the SMC would not hand over fan "
                                           + "\(target.index + 1) — it stays on automatic")
                }
            }
            guard hardware.writeTarget(index: target.index, rpm: safe) else {
                // The mode was taken and the target was not, so put the mode back
                // rather than leave a fan forced to a speed nobody chose.
                if !alreadyHeld, let beforeMode {
                    _ = hardware.writeMode(index: target.index, value: beforeMode)
                }
                return FanReply(ok: false, message: "the SMC refused the write")
            }
            // READ IT BACK. `writeTarget` returning true means the SMC accepted
            // the call, not that the firmware kept the number — and that gap is
            // the exact shape of the bug that made this feature appear to work
            // and do nothing for weeks: the write was accepted, the reply said
            // "set to 2675 rpm", and the fans sat where they were because the
            // mode had never been taken.
            //
            // The TARGET key is safe to check immediately: `F<n>Tg` is the
            // commanded value, not the measured one. The actual speed `F<n>Ac`
            // ramps over seconds and is deliberately not what this compares.
            // RETRIED, because the SMC is a microcontroller and not memory.
            //
            // The first version read once, immediately, on the assumption that
            // `F<n>Tg` is a register that reads back what was just written. That
            // assumption is contradicted a few lines up in this very file:
            // "`F<n>Tg` reads back as whatever the firmware wants rather than what
            // was written". A write has to be taken up before it is visible, and
            // reading in the same breath sees the state before it.
            //
            // Every write was rejected and rolled back to automatic as a result —
            // fan control worked, then did not, and said "the SMC accepted the
            // write and did not keep it" about writes it had kept.
            //
            // Half a second in five looks, giving up as soon as it agrees. A fan
            // ramps over seconds; this is only waiting for the COMMANDED value to
            // appear, not for the blades to move.
            var afterMode = hardware.readMode(index: target.index)
            var afterTarget = hardware.readTarget(index: target.index)
            for _ in 0..<4 where !FanHelperServer.readbackHolds(
                mode: afterMode, target: afterTarget, wanted: safe) {
                usleep(120_000)
                afterMode = hardware.readMode(index: target.index)
                afterTarget = hardware.readTarget(index: target.index)
            }
            guard FanHelperServer.readbackHolds(mode: afterMode,
                                                 target: afterTarget,
                                                 wanted: safe) else {
                // FAIL SAFE. The firmware is not doing what was asked and this
                // helper cannot tell why, so the fan goes back to automatic rather
                // than being left forced to a speed nobody can confirm. Automatic
                // is the state that cannot cook the machine.
                if !alreadyHeld, let beforeMode {
                    _ = hardware.writeMode(index: target.index, value: beforeMode)
                }
                if !alreadyHeld, let before {
                    _ = hardware.writeTarget(index: target.index, rpm: before)
                }
                let modeText = afterMode.map { String($0) } ?? "unreadable"
                let targetText = afterTarget.map { String($0) } ?? "unreadable"
                log("readback disagreed on F\(target.index): mode \(modeText), "
                    + "target \(targetText), wanted \(safe)")
                let sawMode = afterMode.map { String(format: "%.0f", $0) } ?? "unreadable"
                let sawTarget = afterTarget.map { String(format: "%.0f", $0) } ?? "unreadable"
                return FanReply(ok: false,
                                message: "Fan \(target.index + 1) did not keep the write "
                                       + "(mode \(sawMode), target \(sawTarget), asked "
                                       + "\(Int(safe))) — it is back on automatic.")
            }

            // Recorded only once the write actually landed AND read back. A
            // refused write took nothing, and a helper that believes it holds a
            // fan it never touched would write to that fan on its way out.
            holdings.took(target.index, previousTarget: before, previousMode: beforeMode)
            let readBack = afterTarget.map { String($0) } ?? "?"
            log("set F\(target.index)md = \(SMCFanMode.forced), "
                + "F\(target.index)Tg = \(safe) (read back \(readBack))")
            return FanReply(ok: true,
                            message: "fan \(target.index + 1) set to \(Int(safe)) rpm")
        }
    }

    /// Did the SMC keep what it was just given?
    ///
    /// Its own function because the write path around it has no test coverage —
    /// it is private, it talks to real hardware, and this project does not test
    /// fan writes against a live machine on purpose. The DECISION is the part with
    /// the interesting rules, and it is pure, so it can be tested on its own.
    ///
    /// An UNREADABLE mode does not fail, and that is policy rather than leniency:
    /// the take only claims the mode when it could be read AND said automatic, so
    /// a machine whose mode key is unreadable was never having its mode changed.
    /// Failing here would refuse those machines outright, which is a different
    /// decision from the one this check is making.
    ///
    /// A readable mode still saying automatic IS the failure worth catching: the
    /// take was issued, the SMC said yes, and the firmware kept control anyway.
    /// That is the exact shape of the bug that made this feature appear to work
    /// and do nothing — accepted write, confident reply, fans unchanged.
    ///
    /// An unreadable TARGET fails. It is the number just written, and a machine
    /// that cannot read back what it accepted has told us nothing at all.
    public static func readbackHolds(mode: Double?, target: Double?, wanted: Double) -> Bool {
        let modeHeld = mode.map { $0 != SMCFanMode.automatic } ?? true
        // A rounding tolerance, not a range: the SMC stores this as a float and
        // hands back what it was given, so anything past a single rpm is the
        // firmware substituting its own number.
        let targetHeld = target.map { abs($0 - wanted) <= 1 } ?? false
        return modeHeld && targetHeld
    }

    /// Hand back everything this helper holds: the charger, then the fans.
    ///
    /// The one release path — `releaseAll`, the dead man's switch in
    /// `dropClient`, and `shutdownSocket` (which every signal in
    /// `HelperSignals.stop` reaches through `stop()`) all come here.
    @discardableResult
    private func release() -> FanReply {
        // The charger FIRST, and outside the fans' "nothing held" early return:
        // the common case is a discharge with no fan held at all. The fans are
        // released whatever the charger did.
        let charger: ChargeRelease.Result? =
            dischargeTarget != nil || reconnectOwed ? reconnectCharger() : nil
        let hadFans = !holdings.isEmpty
        let fans = releaseFans()
        guard let charger else { return fans }
        let chargerText = "\(charger.message) (released)"
        return FanReply(ok: charger.ok && fans.ok,
                        message: hadFans ? "\(fans.message); \(chargerText)" : chargerText)
    }

    private func releaseFans() -> FanReply {
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
    public static let retiredDaemonLabel = "dev.anode.app.helper"

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
                root.appendingPathComponent("Library/Application Support/Anode/client.cdhash"),
                // The current optional install: a plist and a root-owned copy of
                // the helper. Absent unless the user pressed Install Fan Helper.
                root.appendingPathComponent(String(FanDaemon.plistPath.dropFirst())),
                root.appendingPathComponent(String(FanDaemon.helperPath.dropFirst())),
                // Created by whichever helper is running, and only while it runs.
                root.appendingPathComponent(String(FanSocket.path.dropFirst())),
            ],
            directoriesIfEmpty: [
                root.appendingPathComponent("Library/Application Support/Anode"),
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
