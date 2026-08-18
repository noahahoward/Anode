import Foundation
import IOKit

/// The battery energy scale — the real "100%".
///
/// Deliberately NOT `mAh x instantaneous Voltage`: the readable `Voltage` is a
/// state-of-charge- and load-dependent terminal reading (~12.5 V at 80% SoC on a
/// 3S pack) and overstates full-charge energy by roughly 8%.
///
/// `nominalVoltage` is a seed, and it is STILL the seed — the design calls for
/// replacing the whole scale with a measured `J/%` learned from the gas gauge over
/// a clean on-battery window, which would remove the assumed voltage entirely and
/// track pack ageing. That does not exist. `isCalibrated` below is the only trace
/// of it and is always false.
///
/// This comment used to end "see `calibrated(with:)`", naming a function that was
/// never written — the same claim `ARCHITECTURE.md` made and has since retracted.
/// A cross-reference to nothing is worse than no cross-reference: it reads as
/// evidence the work is done. What the seed costs when it is wrong is written out
/// under "The battery scale" in that file.
public struct BatteryScale {
    public let fullChargeCapacity_mAh: Double
    public let designCapacity_mAh: Double
    public let nominalVoltage_V: Double
    /// True once `joulesPerPercent` came from a measured discharge rather than the seed.
    public let isCalibrated: Bool

    /// 3S Li-ion pack nominal. Seed only — superseded by self-calibration, and
    /// the fallback for `nominalVoltage(measured_mV:)` below.
    public static let seedNominalVoltage_V = 11.58

    /// Per-cell Li-ion nominal. Deliberately `seedNominalVoltage_V / 3`, so a 3S
    /// pack resolves to exactly the old constant — see `nominalVoltage`.
    public static let nominalCellVoltage_V = 11.58 / 3

    /// Nominal pack voltage, inferred from the SERIES CELL COUNT rather than read
    /// off the terminals.
    ///
    /// The instantaneous `Voltage` must NOT be used as the nominal directly, for the
    /// reason this type's own header gives: it moves with state of charge and load
    /// (~12.5 V at 80 % on a 3S pack) and overstates full-charge energy by ~8 %.
    /// That is why the nominal was a constant.
    ///
    /// But a constant 3S nominal is wrong by a WHOLE FACTOR on a pack that is not
    /// 3S, and the seed's error is unbounded in a way the ~8 % it was protecting
    /// against is not. MEASURED on `Mac17,5` (Apple A18 Pro): `Voltage` reads
    /// 4186 mV against `Mac17,9`'s 12111 mV — one cell, not three. The 11.58 V seed
    /// computed 108.2 Wh for a 36.0 Wh pack, a **3.01x** overstatement of
    /// `joulesPerPercent`, which is the denominator under every displayed %/hr. A
    /// measured 2.821 W draw printed as 2.61 %/hr where the truth was 7.25 %/hr,
    /// and implied 30.2 h of runtime where macOS said 10:11 the same minute.
    ///
    /// So the terminal reading is used for the one thing it is reliable for — how
    /// many cells are in series, which no charge level can change — and the per-cell
    /// figure stays a constant. Because `nominalCellVoltage_V` is defined as the
    /// seed over three, a 3S machine resolves to exactly 11.58 V: this change moves
    /// no number on the hardware every measurement in this repo was taken on.
    public static func nominalVoltage(measured_mV: Double?) -> Double {
        guard let mV = measured_mV, mV.isFinite, mV > 0 else { return seedNominalVoltage_V }
        let cells = (mV / 1000 / nominalCellVoltage_V).rounded()
        // Outside this range the field was misread, not attached to a 7S laptop.
        // Fall back to the seed rather than scale by a wrong integer.
        guard cells >= 1, cells <= 4 else { return seedNominalVoltage_V }
        return cells * nominalCellVoltage_V
    }

    public var energyFull_J: Double {
        (fullChargeCapacity_mAh / 1000.0) * nominalVoltage_V * 3600.0
    }

    public var energyFull_Wh: Double { energyFull_J / 3600.0 }

    /// Joules per 1% of battery. This is the denominator every displayed unit divides by.
    public var joulesPerPercent: Double { energyFull_J / 100.0 }

    /// Health as a fraction of design capacity.
    public var health: Double { fullChargeCapacity_mAh / designCapacity_mAh }

    /// Charge remaining as a percent of full, on the mAh BASIS — the one definition
    /// every time-to-empty divides.
    ///
    /// The gauge publishes two answers to "how full is it" and they disagree.
    /// Measured on this machine: `CurrentCapacity` 61 % against
    /// `RemainingCapacity / FullChargeCapacity` = 3667/6193 = 59.2 %, and 42 % against
    /// 40.0 % at another charge — 1-2 points apart, consistently in the same
    /// direction, so the integer field is the OPTIMISTIC one and overstates runtime
    /// by ~5 %, about 12 minutes at 4 hours.
    ///
    /// mAh is the basis to project from, and this is a deliberate change of basis
    /// rather than an accident of which field was nearest: the pack's own
    /// `TimeRemaining` agrees with it. Live, one 60 s window read 4104.8 mW mean at
    /// 11878 mV = 345.6 mA, and 3667 mAh / 345.6 mA = 637 minutes against the gauge's
    /// reported 636. On the integer basis the same arithmetic gives 656.
    ///
    /// Every displayed battery TIME therefore shifts down slightly. The charge
    /// PERCENTAGE shown beside it is deliberately left as the gauge's own
    /// `CurrentCapacity`, because that is the number macOS puts in its own menu bar
    /// and a second opinion about the percentage is not this app's business — which
    /// does mean the printed percentage no longer divides exactly into the printed
    /// hours. `GlanceCardView` records that.
    ///
    /// Falls back to the integer percent when the gauge's mAh fields are missing,
    /// which is the normal case on hardware whose `BatteryData` dict this app has
    /// never seen.
    public func chargePercent(_ s: Battery.State) -> Double {
        guard fullChargeCapacity_mAh > 0, s.remainingCapacity_mAh > 0 else {
            return Double(s.percent)
        }
        return min(100, s.remainingCapacity_mAh / fullChargeCapacity_mAh * 100)
    }
}

public enum Battery {
    // A single tick reads these properties several times over — Battery.state(),
    // PowerTelemetry.sample(), and the capacity scale each want a slice of the same
    // dictionary. Each call is a full IORegistryEntryCreateCFProperties that builds
    // the entire AppleSmartBattery tree including the nested BatteryData and
    // PowerTelemetryData dicts, so doing it three times per tick was pure waste.
    //
    // A very short TTL collapses those into one read while staying far below the
    // ~60 s republish cadence of the underlying counters, so no caller can observe
    // staler data than it would have got anyway.
    private static let cacheTTL: TimeInterval = 0.25
    private static var cached: (props: [String: Any], at: Date)?
    private static let cacheLock = NSLock()

    /// Raw property dictionary from the AppleSmartBattery IORegistry node.
    /// Cached for `cacheTTL` and safe to call from any thread.
    public static func properties() -> [String: Any]? {
        cacheLock.lock()
        if let c = cached, Date().timeIntervalSince(c.at) < cacheTTL {
            cacheLock.unlock()
            return c.props
        }
        cacheLock.unlock()

        guard let fresh = readProperties() else { return nil }

        cacheLock.lock()
        cached = (fresh, Date())
        cacheLock.unlock()
        return fresh
    }

    private static func readProperties() -> [String: Any]? {
        let match = IOServiceMatching("AppleSmartBattery")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, match)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = unmanaged?.takeRetainedValue() as? [String: Any]
        else { return nil }
        return dict
    }

    /// The (remaining, full) field pair a machine publishes its charge in.
    ///
    /// PAIRED, never resolved independently, and that is the entire point of this
    /// table. MEASURED on `Mac17,5` (A18 Pro), whose `BatteryData` carries no
    /// `RemainingCapacity` at all — its dict is gauge-algorithm internals (`DOD0`,
    /// `Qmax`, `Ra00`..`Ra14`, `ChemID`) and the charge lives under other names:
    ///
    ///     AppleRawCurrentCapacity / AppleRawMaxCapacity   7528 / 9530 = 79.0 %
    ///     TrueRemainingCapacity   / NominalChargeCapacity 7399 / 9340 = 79.2 %
    ///     ... but CROSSING them                                        80.6 % / 77.6 %
    ///
    /// That 1.6-point spread is the same order of error as the integer
    /// `CurrentCapacity` basis this app already refuses to use — and unlike a
    /// missing field it would be silent, because both halves are real fields
    /// holding plausible numbers.
    ///
    /// Order is priority. The first pair is what `Mac17,9` publishes, and reading
    /// it is what this app already did before the table existed, so no number moves
    /// on that hardware.
    static let capacityPairs: [(remaining: String, full: String)] = [
        ("RemainingCapacity",       "FullChargeCapacity"),
        ("TrueRemainingCapacity",   "NominalChargeCapacity"),
        ("AppleRawCurrentCapacity", "AppleRawMaxCapacity"),
    ]

    /// First pair this machine answers BOTH halves of.
    ///
    /// Both or neither: a pair answering only one half is not a basis, and falling
    /// through for just the missing half is precisely the crossing above.
    ///
    /// Each half is looked for in `BatteryData` and then at the top level, because
    /// which dict holds a given field is itself model-specific — on `Mac17,5`
    /// `TrueRemainingCapacity` is nested and `NominalChargeCapacity` is not.
    static func resolveCapacity(_ props: [String: Any])
        -> (remaining_mAh: Double, full_mAh: Double)? {
        let data = props["BatteryData"] as? [String: Any] ?? [:]
        func look(_ k: String) -> Double? {
            if let v = data[k] as? NSNumber, v.doubleValue > 0 { return v.doubleValue }
            if let v = props[k] as? NSNumber, v.doubleValue > 0 { return v.doubleValue }
            return nil
        }
        for pair in capacityPairs {
            if let r = look(pair.remaining), let f = look(pair.full) { return (r, f) }
        }
        return nil
    }

    /// TRAP: on Apple Silicon the top-level `MaxCapacity`/`CurrentCapacity` are PERCENT,
    /// not mAh. The real mAh values live only in the nested `BatteryData` dict.
    public static func scale() -> BatteryScale? {
        guard let props = properties() else { return nil }
        let data = props["BatteryData"] as? [String: Any] ?? [:]

        func mAh(_ keys: [String]) -> Double? {
            for k in keys {
                if let v = data[k] as? NSNumber, v.doubleValue > 0 { return v.doubleValue }
                if let v = props[k] as? NSNumber, v.doubleValue > 0 { return v.doubleValue }
            }
            return nil
        }

        guard let design = mAh(["DesignCapacity"]) else { return nil }
        // The PAIR's full half whenever a pair resolves, so this and `state()` are
        // never on different bases. The independent lookup survives as a fallback:
        // a machine publishing a capacity but no readable remaining charge still
        // gets a usable energy scale, which is strictly what it had before.
        let full = resolveCapacity(props)?.full_mAh
            ?? mAh(["FullChargeCapacity", "NominalChargeCapacity", "AppleRawMaxCapacity"])
            ?? design

        return BatteryScale(
            fullChargeCapacity_mAh: full,
            designCapacity_mAh: design,
            nominalVoltage_V: BatteryScale.nominalVoltage(
                measured_mV: (props["Voltage"] as? NSNumber)?.doubleValue),
            isCalibrated: false
        )
    }

    public struct State {
        public let percent: Int          // charge %, gas gauge
        public let isCharging: Bool
        public let onAC: Bool
        public let cycleCount: Int
        public let voltage_mV: Int
        public let amperage_mA: Int      // signed; negative = discharging
        public let remainingCapacity_mAh: Double

        /// `65535` is the SBS "unknown" sentinel, returned whenever on AC and for
        /// minutes after unplugging. Never treat it as a real time estimate.
        public let timeRemaining_min: Int?

        /// Why the charger is idle, from the nested `ChargerData` dict. Zero means
        /// "no reason" — either charging normally or nothing is plugged in.
        ///
        /// This and `fullyCharged` are the only evidence this machine gives that a
        /// charge LIMIT exists (see `ChargeLimitLearner`): nothing in IOKit states
        /// the limit, but a machine on AC that is deliberately not charging while
        /// not full has stopped somewhere on purpose.
        ///
        /// TRAP, verified live: this keeps its last value after the adapter is
        /// unplugged — read 128 at 83% on battery. It is only meaningful with
        /// `onAC`, and every caller must pair them.
        ///
        /// Defaulted so the existing synthetic fixtures keep describing a battery
        /// without restating a field they have no opinion about.
        public var notChargingReason: Int = 0
        /// The gauge's own "this pack is full", distinct from `percent >= 99` and
        /// from any limit. False while holding at 80%, which is what makes the
        /// two distinguishable at all.
        public var fullyCharged: Bool = false
    }

    public static func state() -> State? {
        guard let props = properties() else { return nil }
        let data = props["BatteryData"] as? [String: Any] ?? [:]

        func int(_ key: String, _ src: [String: Any]? = nil) -> Int {
            ((src ?? props)[key] as? NSNumber)?.intValue ?? 0
        }

        let raw = int("TimeRemaining")
        let sane = (raw > 0 && raw != 65535) ? raw : nil
        let charger = props["ChargerData"] as? [String: Any] ?? [:]

        return State(
            percent: int("CurrentCapacity"),
            isCharging: props["IsCharging"] as? Bool ?? false,
            onAC: props["ExternalConnected"] as? Bool ?? false,
            cycleCount: int("CycleCount") != 0 ? int("CycleCount") : int("CycleCount", data),
            voltage_mV: int("Voltage"),
            amperage_mA: int("InstantAmperage") != 0 ? int("InstantAmperage") : int("Amperage"),
            // The pair `scale()` resolved, not `BatteryData.RemainingCapacity`
            // alone. Reading that one field with no fallback — while `scale()` three
            // functions up tried three names across two dicts — is what made this
            // read 0 on `Mac17,5` and take the whole drain estimator down with it:
            // `DrainRateEstimator.record` drops every sample on `guard mAh > 0`, so
            // `estimate()` returns nil, `reconciledRate` publishes `windowSpan: 0`,
            // and `canQuoteTime` never opens. The UI said "measuring…" for as long
            // as the app ran, with the RATE still reading fine off the power tier —
            // which is the tell, and why it took a second machine to find.
            remainingCapacity_mAh: Self.resolveCapacity(props)?.remaining_mAh ?? 0,
            timeRemaining_min: sane,
            notChargingReason: int("NotChargingReason", charger),
            fullyCharged: props["FullyCharged"] as? Bool ?? false
        )
    }
}
