import Foundation
import notify

// What the root helper does to the charger: set macOS's own charge limit, and
// cut or reconnect the adapter. Policy — when, to what, for how long — lives in
// `FanHelperServer` and above it; nothing in this file decides anything.

/// The charger, behind a protocol, for the same reason `FanHardware` is: the
/// server's refusals and its reconnect-on-every-exit can be tested against a
/// fake. A cut made by a test on a real machine OUTLIVES the test process
/// (measured: `kill -9` left `CHIE` = 08 and the charger disconnected).
public protocol ChargeHardware: AnyObject {
    /// Is the charger cut right now? nil when the key cannot be read. Any
    /// non-zero value reads as cut: this is the question a reconnect's
    /// READ-BACK asks (only 0x00 is connected).
    func adapterCut() -> Bool?
    /// The byte the adapter-cut key holds right now, nil when it cannot be
    /// read. Tells Anode's own cut — `AdapterCutKey.cut`, the only non-zero
    /// value it writes — from a value nobody here has measured, which a
    /// reconnect holding nothing leaves alone (`ChargeRelease.reconnect`). A
    /// cut's read-back asks this, and takes only exactly 0x08.
    func adapterCutValue() -> UInt8?
    /// Cut (true) or reconnect (false). The only two writes the helper makes to
    /// the charger. True means the SMC said yes to the write — neither that
    /// the charger changed nor, when false, that it did not: `ChargeRelease`
    /// reads every write back and decides by the read alone.
    func setAdapterCut(_ on: Bool) -> Bool
    func batteryPercent() -> Int?
    /// Is a charger on the cable? Answered the same while the charger is cut
    /// as while it is not: Anode's own cut does not read as a pulled cable (see
    /// `ChargeAC.presence`). nil only when the battery cannot be read at all.
    func onAC() -> Bool?
    /// Set macOS's own charge limit (`mclLimitValue`), 0…100.
    func writeChargeLimit(_ percent: Int) -> Bool
    /// Does this Mac have the adapter-cut key at all? Tells "no such key" (a
    /// Mac this helper can never have cut) from "unreadable" (one it may
    /// have). False only when the SMC itself says the key is not there; true
    /// whenever it cannot be told. Never asked while this helper holds a cut:
    /// a cut that read back already proved the key exists.
    func adapterCutKeyExists() -> Bool
}

public extension ChargeHardware {
    /// The cautious answer: a key that might exist is treated as one that does,
    /// so a failure to reconnect is reported rather than explained away.
    func adapterCutKeyExists() -> Bool { true }

    /// For a charger that can only say cut or not: a cut is taken to be
    /// Anode's own value, so such a charger is reconnected exactly as before.
    func adapterCutValue() -> UInt8? {
        adapterCut().map { $0 ? AdapterCutKey.cut : AdapterCutKey.connected }
    }
}

/// The adapter-cut key and the only two values ever written to it.
///
/// MEASURED on macOS 27: `CHIE` is `hex_`, one byte; 0x08 cuts the charger
/// with the cable still in, 0x00 reconnects it. Root alone suffices. Any other
/// value has never been observed and is never written.
public enum AdapterCutKey {
    public static let key = "CHIE"
    public static let cut: UInt8 = 0x08
    public static let connected: UInt8 = 0x00
}

/// When a discharge has to end. Pure, so it can be pinned by tests.
public struct DischargeWatch {
    /// Never discharge below this, whatever the target says.
    public static let floor = 10

    /// True when the charger must be reconnected now: the battery cannot be
    /// read, it has reached `max(target, floor)`, or the cable is known to be
    /// out. An UNKNOWN cable (`onAC == nil`) is not "out": it is what the
    /// hardware reports when the battery cannot be read at all.
    public static func shouldRestore(target: Int, percent: Int?, onAC: Bool?) -> Bool {
        guard let percent else { return true }
        if percent <= max(target, floor) { return true }
        return onAC == false
    }
}

/// Cutting and reconnecting the charger, each write READ BACK.
///
/// ONE implementation, used by the server's dead man's switch, its watch, its
/// startup clear, `stopDischarge`, the failed-cut path, and `--uninstall` — the
/// same rule `FanRelease` follows for the fans, for the same reason: copies of
/// a write this consequential drift apart.
///
/// A write the SMC accepted is not a write the SMC applied, and a write it
/// answered with an error is not proof that nothing changed. `setAdapterCut`'s
/// answer is logged, never trusted; only reading `CHIE` again says what the
/// charger is doing. So a reconnect is DONE when the key reads connected, and a
/// cut is done when the key reads exactly 0x08. Anything else is a failure, reported as
/// one. (The SMC's result byte for a good `CHIE` write has never been measured:
/// nothing here may depend on it being 0.)
public enum ChargeRelease {

    /// How an `.unrecognised` answer begins: a stop (or a startup clear, or an
    /// uninstall) that found the key holding a value Anode never writes, and
    /// left it. The reply is ok — it is not Anode's cut — but it is not
    /// "connected" either, and the app tells it apart by these words.
    public static let notAnodesValue = "the charger switch holds a value Anode did not write"

    /// How hard to try. A few reads a moment apart per write, because the SMC is
    /// a microcontroller and a read in the same breath as the write may still see
    /// the old value (the fan read-back in `FanHelperServer.set` learned this).
    /// Worst case for `standard` is about 0.65 s: this runs on the helper's loop
    /// thread, so it has to stay short.
    public struct Timing: Equatable {
        public var tries: Int
        public var readsPerTry: Int
        public var readPause: TimeInterval
        public var retryPause: TimeInterval

        public init(tries: Int, readsPerTry: Int, readPause: TimeInterval, retryPause: TimeInterval) {
            self.tries = tries
            self.readsPerTry = readsPerTry
            self.readPause = readPause
            self.retryPause = retryPause
        }

        public static let standard = Timing(tries: 3, readsPerTry: 4, readPause: 0.05, retryPause: 0.1)
        /// No waiting at all — for tests, whose fake applies a write at once.
        public static let immediate = Timing(tries: 3, readsPerTry: 1, readPause: 0, retryPause: 0)
    }

    public struct Result: Equatable {
        public enum Outcome: Equatable {
            /// It read connected; nothing was written.
            case notCut
            /// The SMC says this Mac has no adapter-cut key. Never the answer
            /// while a cut is held (`reconnect(holding:)`).
            case noKey
            /// Written, and it then read connected.
            case reconnected
            /// Written, and it STILL reads cut.
            case stillCut
            /// Written, and it could not be read back, so nobody knows.
            case unconfirmed
            /// It reads a value Anode never writes — neither 0x00 nor 0x08 —
            /// and this reconnect holds no cut and owes none, so nothing was
            /// written. Not Anode's cut, and not Anode's to overwrite: nobody
            /// here has measured what it means. Never the answer while a cut
            /// is held or owed (`reconnect(holding:)`).
            ///
            /// Ok, because it is not Anode's by construction: a cut is taken
            /// only when it reads back exactly 0x08, and any other read-back
            /// is undone with 0x00 (`cut`), so no value but 0x08 is ever left
            /// by Anode. Its message says so in words of its own
            /// (`notAnodesValue`), so the app does not take it for "connected".
            case unrecognised(UInt8)
        }

        public let outcome: Outcome
        /// Reconnect writes made.
        public let writes: Int

        public init(_ outcome: Outcome, writes: Int) {
            self.outcome = outcome
            self.writes = writes
        }

        public var ok: Bool {
            switch outcome {
            case .notCut, .noKey, .reconnected, .unrecognised: return true
            case .stillCut, .unconfirmed:                      return false
            }
        }

        public var message: String {
            switch outcome {
            case .notCut:      return "the charger is not cut — nothing to reconnect"
            case .noKey:       return "this Mac has no adapter-cut key — nothing to reconnect"
            case .reconnected: return "charger reconnected"
            case .unrecognised(let value):
                return ChargeRelease.notAnodesValue + " (" + String(format: "0x%02X", value)
                     + "); Anode leaves it alone"
            case .stillCut:
                return "the charger did NOT reconnect — it still reads as cut off after "
                     + "\(writes) tr\(writes == 1 ? "y" : "ies")"
            case .unconfirmed:
                return "the charger could not be read back after \(writes) reconnect "
                     + "write\(writes == 1 ? "" : "s") — it may still be cut off"
            }
        }
    }

    /// Reconnect the charger and confirm it.
    ///
    /// Holding nothing — the startup clear, a stop with no discharge held,
    /// `--uninstall` — it reads the key first and writes ONLY WHEN IT READS
    /// ANODE'S OWN CUT, 0x08. So the everyday path, a helper starting on a
    /// charger nobody cut, writes nothing; and a value Anode never writes is
    /// left alone (`.unrecognised`) rather than written over with 0x00 as
    /// though Anode had put it there. A key that cannot be read IS written,
    /// unless the SMC itself says there is no such key
    /// (`adapterCutKeyExists`): an unreadable key is not a value read, it may
    /// be the cut a killed helper left, and reconnecting cannot hurt where
    /// leaving that cut in place can.
    ///
    /// `alwaysWrite` skips that first read. It is for straight after a cut
    /// attempt, when a read may still show the state from before the write and
    /// "it reads connected" proves nothing.
    ///
    /// `holding` is for a caller that holds a cut which READ BACK cut, or owes
    /// a reconnect: the key is known to exist. Then the reconnect is always
    /// written, whatever the key reads, and the answer is never `.noKey` — not
    /// on a first read that fails, and not after writes that cannot be read
    /// back. A failed read there is a failed read, and the key-info question
    /// that would follow can fail the same way and answer "no such key";
    /// taking its word once left a held cut unwritten, its target cleared, and
    /// nobody watching.
    public static func reconnect(_ charge: ChargeHardware,
                                 alwaysWrite: Bool = false,
                                 holding: Bool = false,
                                 timing: Timing = .standard) -> Result {
        if !alwaysWrite && !holding {
            switch charge.adapterCutValue() {
            case .some(AdapterCutKey.connected):
                return Result(.notCut, writes: 0)
            case .some(AdapterCutKey.cut):
                break
            case .some(let other):
                return Result(.unrecognised(other), writes: 0)
            case nil where !charge.adapterCutKeyExists():
                return Result(.noKey, writes: 0)
            case nil:
                break
            }
        }
        let tries = max(timing.tries, 1)
        var outcome = Result.Outcome.unconfirmed
        for attempt in 0..<tries {
            if attempt > 0 { pause(timing.retryPause) }
            // The write's own answer is not the test; the read is. A write
            // "refused" in-band that landed anyway still reads connected.
            _ = charge.setAdapterCut(false)
            switch readBack(charge, expecting: false, timing: timing) {
            case false?: return Result(.reconnected, writes: attempt + 1)
            case true?:  outcome = .stillCut
            case nil:    outcome = .unconfirmed
            }
        }
        // A key that is not there cannot be cut; say that rather than "may still
        // be cut off" about a Mac that has no way to be. Never about a cut this
        // caller holds: that one read back, so the key is there.
        if outcome == .unconfirmed, !holding, !charge.adapterCutKeyExists() {
            return Result(.noKey, writes: tries)
        }
        return Result(outcome, writes: tries)
    }

    /// What a cut came to. Decided by READING `CHIE` BACK, never by the
    /// write's own answer, which only picks the words: the SMC's result byte
    /// for a good `CHIE` write has not been measured, and trusting it would
    /// refuse every discharge on a Mac that answers a good write with non-zero.
    /// "Reads cut" means reads EXACTLY `AdapterCutKey.cut`: any other non-zero
    /// value is one nobody here has measured, and Anode must never be left
    /// holding it.
    public enum CutOutcome: Equatable {
        /// It reads 0x08, and the write said yes.
        case cut
        /// It reads 0x08, and the write said no. A cut all the same; the answer
        /// is worth a log line, because it is the unmeasured case.
        case cutAlthoughRefused
        /// It does not read 0x08 (0x00, another value, or unreadable), and the
        /// write said no.
        case refused
        /// It does not read 0x08 (0x00, another value, or unreadable), and the
        /// write said yes.
        case notKept

        /// The charger reads cut: the discharge is on.
        public var isCut: Bool { self == .cut || self == .cutAlthoughRefused }
    }

    /// Cut the charger and confirm it by reading it back. Anything not `isCut`
    /// must be followed by `reconnect(alwaysWrite: true)`: a write that did not
    /// provably cut may still land, and a value other than 0x08 that it left is
    /// written back to 0x00 that way, and judged by that read-back.
    ///
    /// `taken` is called as soon as the SMC has answered the write yes, before the read-back: from then on there may be
    /// a cut, whatever the read-back says or whether it can be made at all.
    public static func cut(_ charge: ChargeHardware, timing: Timing = .standard,
                           taken: (() -> Void)? = nil) -> CutOutcome {
        let accepted = charge.setAdapterCut(true)
        if accepted { taken?() }
        let readsCut = readBackValue(charge, expecting: AdapterCutKey.cut, timing: timing) == AdapterCutKey.cut
        switch (readsCut, accepted) {
        case (true, true):   return .cut
        case (true, false):  return .cutAlthoughRefused
        case (false, false): return .refused
        case (false, true):  return .notKept
        }
    }

    /// Read the key until it says `expecting`, a few times a moment apart, and
    /// return the last reading.
    static func readBack(_ charge: ChargeHardware, expecting cut: Bool, timing: Timing) -> Bool? {
        var seen = charge.adapterCut()
        var reads = 1
        while seen != cut, reads < max(timing.readsPerTry, 1) {
            pause(timing.readPause)
            seen = charge.adapterCut()
            reads += 1
        }
        return seen
    }

    /// The same for an exact value: read until the key holds `value`, and
    /// return the last reading.
    static func readBackValue(_ charge: ChargeHardware, expecting value: UInt8, timing: Timing) -> UInt8? {
        var seen = charge.adapterCutValue()
        var reads = 1
        while seen != value, reads < max(timing.readsPerTry, 1) {
            pause(timing.readPause)
            seen = charge.adapterCutValue()
            reads += 1
        }
        return seen
    }

    private static func pause(_ seconds: TimeInterval) {
        guard seconds > 0 else { return }
        usleep(useconds_t(seconds * 1_000_000))
    }
}

/// What "is a charger on the cable" means while the helper may be cutting it.
public enum ChargeAC {
    /// MEASURED on `Mac17,9`, macOS 27.0, in the Plan 0 snapshots:
    ///
    ///     state                           ExternalConnected  AdapterDetails
    ///     cable out                       No                 {"FamilyCode"=0}
    ///     on the charger                  Yes                {"Watts"=100,…}
    ///     charger cut by CHIE = 08,       No                 the same as on the
    ///     cable in (48 s into the cut)                       charger
    ///
    /// `ExternalConnected` alone cannot tell a pulled cable from Anode's own
    /// cut, so it is read with `adapterPresent`
    /// (`Battery.adapterPresent(fromProperties:)`), which can. (Measured
    /// later: a cut made while a macOS charge limit below the battery level
    /// was in force left `ExternalConnected` at Yes; see the measurements
    /// there.
    /// Either answer saying yes is enough here, so that state reads as a
    /// charger on the cable too.)
    ///
    /// - `true` when either says so: the flag on the charger, the details
    ///   during a cut. A Mac whose details are empty on the charger is still
    ///   on it.
    /// - `false` when neither does: the cable is out, and a discharge ends.
    /// - `nil` only when the battery cannot be read at all (both nil). A
    ///   reading that says no with none that says yes is `false`, the
    ///   direction that reconnects the charger and cannot hurt. It does not
    ///   arise on the hardware, where both come from one `Battery.state()`.
    public static func presence(externalConnected: Bool?, adapterPresent: Bool?) -> Bool? {
        if externalConnected == true || adapterPresent == true { return true }
        if externalConnected == nil && adapterPresent == nil { return nil }
        return false
    }
}

/// `ChargeHardware` over the real SMC, battery and preferences. Needs root for
/// every write. No policy: range checks and the discharge floor are the
/// server's.
public final class SystemChargeHardware: ChargeHardware {
    private let smc: SMC?

    /// The preference macOS's Charge Limit setting is stored in, and the
    /// notification that makes PowerUIAgent re-read it (measured: applied within
    /// about 6 s). Written as root this lands in
    /// /var/root/Library/Preferences/com.apple.smartcharging.topoffprotection.plist.
    public static let limitDomain = "com.apple.smartcharging.topoffprotection"
    public static let limitKey = "mclLimitValue"
    public static let limitChanged = "com.apple.smartcharging.defaultschanged"

    public init(smc: SMC? = SMC()) {
        self.smc = smc
    }

    public func adapterCut() -> Bool? {
        adapterCutValue().map { $0 != AdapterCutKey.connected }
    }

    public func adapterCutValue() -> UInt8? {
        smc?.readByte(AdapterCutKey.key)
    }

    public func setAdapterCut(_ on: Bool) -> Bool {
        smc?.writeByte(AdapterCutKey.key, on ? AdapterCutKey.cut : AdapterCutKey.connected) ?? false
    }

    /// Key info only — no read of the value, no write. False only on the
    /// SMC's own "no such key" (`SMC.isAbsent`); a call that fails, or
    /// anything else, is the cautious true. Without an SMC connection nothing
    /// can be told, and the answer is the cautious one. Not `SMC.exists`, which
    /// answers false for ANY failed call.
    public func adapterCutKeyExists() -> Bool {
        guard let smc else { return true }
        return !smc.isAbsent(AdapterCutKey.key)
    }

    public func batteryPercent() -> Int? {
        Battery.state()?.percent
    }

    public func onAC() -> Bool? {
        // One read, so the two answers describe the same moment.
        let state = Battery.state()
        return ChargeAC.presence(externalConnected: state?.onAC,
                                 adapterPresent: state?.adapterPresent)
    }

    public func writeChargeLimit(_ percent: Int) -> Bool {
        guard (0...100).contains(percent) else { return false }
        let domain = Self.limitDomain as CFString
        CFPreferencesSetValue(Self.limitKey as CFString,
                              NSNumber(value: percent),
                              domain,
                              kCFPreferencesCurrentUser,
                              kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            return false
        }
        return notify_post(Self.limitChanged) == UInt32(NOTIFY_STATUS_OK)
    }
}
