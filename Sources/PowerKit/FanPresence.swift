import Foundation

/// Does this machine have fans at all?
///
/// The Fans tab is hidden on a machine that has none — a MacBook Air, or the
/// fanless desktop the author calls the Neo — because a tab whose entire content
/// is "there is nothing here" is worse than no tab.
///
/// HIDING A TAB IS A CLAIM ABOUT THE HARDWARE, so it is made only on evidence.
/// Three states, not two, for the same reason every other unknown in this
/// codebase is kept distinguishable from zero: a failure to READ the SMC is not
/// a machine with no fans. That distinction has already bitten this app once —
/// the Fans pane printed "This machine reports no fans" on a machine with two,
/// because the sweep had been skipped while the window was hidden and an empty
/// list read identically to a fanless Mac.
///
/// `FNum` is the signal. It is a `ui8` the SMC has published since the Intel
/// era, it reads 2 on this machine, and it is the machine's own count rather
/// than an inference from which keys happen to decode.
public enum FanPresence {

    public enum State: Equatable {
        /// The SMC answered and this many fans exist.
        case fans(Int)
        /// The SMC answered and said zero. This is the only state that hides the tab.
        case fanless
        /// Nobody has measured it: the SMC would not open, or it did and neither
        /// `FNum` nor any `F<n>Ac` key exists to answer with.
        case unknown
    }

    /// Whether the Fans tab is offered.
    ///
    /// `.unknown` SHOWS the tab, deliberately. The two ways to be wrong are not
    /// symmetric: showing the tab on a fanless machine costs one pane that says
    /// so in words ("Either it is fanless, or the SMC keys differ on this
    /// model"), while hiding it on a machine that has fans silently removes a
    /// reading the user came for and leaves nothing to suggest it ever existed.
    public static func showsFanTab(_ state: State) -> Bool {
        switch state {
        case .fanless:          return false
        case .fans, .unknown:   return true
        }
    }

    /// The decision, as arithmetic over what the hardware said.
    ///
    /// Split from the probe so every branch can be tested on a machine that has
    /// fans — the fanless case is otherwise only reachable by owning a different
    /// Mac.
    ///
    /// `respondingFans` is how many `F<n>Ac` keys actually decoded, and it wins
    /// over a zero `FNum` because a fan that reports a speed is direct evidence
    /// of a fan, while `FNum` is a claim about them. They should never disagree;
    /// if they do, believing the one backed by a live reading is the honest way
    /// round.
    /// `smcAnswering` is evidence the connection is live rather than merely open —
    /// `detect` passes `#KEY > 0`. It defaults to false so a caller that cannot
    /// establish it gets the old, cautious `.unknown`.
    public static func decide(smcReachable: Bool,
                              reportedCount: Double?,
                              respondingFans: Int,
                              smcAnswering: Bool = false) -> State {
        // Not measured. Never "none".
        guard smcReachable else { return .unknown }

        if let n = plausibleCount(reportedCount) {
            guard n == 0 else { return .fans(n) }
            return respondingFans > 0 ? .fans(respondingFans) : .fanless
        }

        // No usable FNum. A responding fan key still proves fans exist.
        if respondingFans > 0 { return .fans(respondingFans) }

        // Neither a count nor a fan key. This used to return `.unknown`
        // unconditionally, because `respondingFans` meant "how many `F<n>Ac` keys
        // DECODED" and on Intel `F<n>Ac` is `fpe2`, a type this app's decoder skips
        // — so an Intel Mac with two fans landed here and hiding the tab would have
        // been wrong. `detect` now counts keys that EXIST rather than keys that
        // decode (see `SMC.exists`), which removes that case entirely: an Intel fan
        // key is present whether or not its type can be read.
        //
        // What is left is a genuine absence, and it is worth distinguishing from a
        // dead connection. MEASURED on `Mac17,5` (A18 Pro): the SMC opens, publishes
        // 2334 keys, and **not one of them begins with `F`**. A connection answering
        // for thousands of keys and holding no fan key at all is evidence of
        // fanless, not evidence of nothing.
        return smcAnswering ? .fanless : .unknown
    }

    /// `FNum` is a `ui8`, so a fractional or enormous value is a misdecoded key
    /// rather than a fan count, and must not be believed in either direction.
    private static func plausibleCount(_ v: Double?) -> Int? {
        guard let v, v.isFinite, v >= 0, v <= 10, v == v.rounded() else { return nil }
        return Int(v)
    }

    /// Ask the hardware. Costs ONE SMC key read on a machine that publishes
    /// `FNum` with a non-zero count, which is every machine with fans; the ten
    /// `F<n>Ac` probes are paid only when `FNum` is missing or says zero, and
    /// they are what stops a missing count key from being read as "no fans".
    ///
    /// This opens its own SMC connection rather than going through
    /// `Sensors.inventory()`, which walks 3,588 keys at ~0.7 s. The fan count
    /// cannot change while the machine is running, so it is read once.
    public static func detect() -> State {
        guard let smc = SMC() else { return .unknown }
        let reported = smc.read("FNum")?.value
        if let n = plausibleCount(reported), n > 0 { return .fans(n) }
        // EXISTS, not decodes — see `SMC.exists`. A fan key of a type this app
        // cannot read is still a fan.
        let responding = (0..<10).filter { smc.exists("F\($0)Ac") }.count
        // One more read, and only on the path that is about to conclude an absence:
        // a machine with fans answered `FNum` above and never reaches here.
        let answering = responding > 0 || smc.keyCount() > 0
        return decide(smcReachable: true, reportedCount: reported,
                      respondingFans: responding, smcAnswering: answering)
    }

    /// Read once, at first use, and held for the life of the process — a Mac does
    /// not grow a fan while it is running. The rail and the View menu both read
    /// this, so they cannot disagree about whether the tab exists.
    public static let onThisMac: State = detect()
}
