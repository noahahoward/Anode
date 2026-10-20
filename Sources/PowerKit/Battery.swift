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
    /// The capacity macOS rates health by: `NominalChargeCapacity`. Nil where
    /// the gauge does not publish it, and then health falls back to
    /// `fullChargeCapacity_mAh`. See `health`.
    public var healthCapacity_mAh: Double? = nil

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
    public static func nominalVoltage(measured_mV: Double?, cellCount: Int? = nil) -> Double {
        // The gauge's per-cell voltage array, when it publishes one, IS the cell
        // count — no rounding of a terminal voltage that sags under load. A 3S
        // pack near empty under a heavy load reads ~9.3 V, which rounds to TWO
        // cells; the array still has three entries.
        if let n = cellCount, (1...4).contains(n) { return Double(n) * nominalCellVoltage_V }
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

    /// %/hr that `watts` costs at the pack's LIVE voltage — current as a share of
    /// full-charge capacity. The discharge tier's rates are on this basis (it
    /// divides a measured current by capacity), and `timeToEmpty` assumes it.
    /// `joulesPerPercent` is on the NOMINAL-voltage basis instead, which is up to
    /// ~7 % away at a full pack; two rates that are compared or mixed have to be
    /// converted the same way, and this is the way that matches the gauge.
    public func pctHrAtVoltage(watts: Double, voltage_mV: Double) -> Double {
        watts * 1e8 / (voltage_mV * fullChargeCapacity_mAh)
    }

    /// Health as a fraction of design capacity — the number System Settings
    /// calls "Maximum Capacity", which is `NominalChargeCapacity / DesignCapacity`.
    ///
    /// It divided whichever capacity pair the charge basis resolved to, so the
    /// same question got different answers on different Macs: `Mac17,9`
    /// resolves `FullChargeCapacity` (5972 / 6249 = 95.6 %) where macOS's own
    /// figure is 6124 / 6249 = 98.0 %, while a MacBook Neo resolves the nominal
    /// one. Capped at 100 %, as System Settings caps it: a new pack's nominal
    /// capacity routinely reads a few percent over its design figure.
    public var health: Double {
        guard designCapacity_mAh > 0 else { return 0 }
        return min(1, (healthCapacity_mAh ?? fullChargeCapacity_mAh) / designCapacity_mAh)
    }

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
                measured_mV: (props["Voltage"] as? NSNumber)?.doubleValue,
                // Live cells only, so a fixed-size array padded with zeros
                // cannot claim a cell that is not there.
                cellCount: (data["CellVoltage"] as? [NSNumber])?
                    .filter { $0.doubleValue > 0 }.count),
            isCalibrated: false,
            healthCapacity_mAh: mAh(["NominalChargeCapacity"])
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

        /// What the adapter is putting in, `PowerTelemetryData.SystemPowerIn`, mW.
        /// Steady while the adapter is at its limit (18.77 W for 25 samples on a
        /// 20 W brick), so it is safe to read at the gauge's own pace.
        ///
        /// Not verified to clear on unplug, so `acPowerText` pairs it with `onAC`.
        public var adapterInput_mW: Double? = nil

        /// "used/supplied" in watts, e.g. "23/18W"; nil when the adapter is not
        /// connected or its input was not read. One decimal below 10 W, where a
        /// whole number would round a light load to something misleading.
        ///
        /// USED IS DERIVED, not read from `SystemLoad`: supplied minus the pack's
        /// own power (signed V × I; negative while it discharges). Energy balance,
        /// and `SystemLoad` obeys it exactly (23922 = 18764 + 5158 live). It is
        /// derived because `SystemLoad` is a single point sample of a load that
        /// swings 12-24 W between gauge batches, published on a different cadence
        /// from the pack current — so the two disagreed, and the widget read
        /// "12/19W" beside a measured 4.9 %/hr DRAIN. Built from the same current
        /// the charge/drain rate uses, the pair cannot contradict it.
        ///
        /// A half that is 0 is "not measured yet", shown as "--": right after
        /// plugging in, `SystemPowerIn` reads 0 until the next batch publishes
        /// (verified live), and a machine on AC drawing nothing does not exist.
        public var acPowerText: String? {
            guard onAC, let input = adapterInput_mW, input.isFinite, input >= 0,
                  voltage_mV > 0 else { return nil }
            func w(_ mW: Double) -> String {
                if mW <= 0 { return "--" }
                let v = mW / 1000
                return v < 10 ? String(format: "%.1f", v) : String(format: "%.0f", v)
            }
            guard input > 0 else { return "--/--W" }
            let pack_mW = Double(amperage_mA) * Double(voltage_mV) / 1000
            return "\(w(input - pack_mW))/\(w(input))W"
        }
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
        let telemetry = props["PowerTelemetryData"] as? [String: Any] ?? [:]
        func mW(_ key: String) -> Double? {
            (telemetry[key] as? NSNumber).map { Double($0.uint64Value) }
        }
        let input = mW("SystemPowerIn")

        var state = State(
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
        state.adapterInput_mW = input
        return state
    }
}

// ─────────────────────────────────────────────────────────────────────────────

extension BatteryScale {

    /// THE PACK'S DISCHARGE CURVE, as a SHAPE.
    ///
    /// Voltage relative to its own value at 50 % state of charge. Normalised on
    /// purpose: the only thing anything here asks of this table is the RATIO of
    /// two points on it, so every absolute scale — cell count, nominal voltage,
    /// capacity, units — cancels out. That is what makes this portable where
    /// `seedNominalVoltage_V` is not. A different pack has a different scale and
    /// very nearly the same shape; it does not have a different 11.58 V.
    ///
    /// Measured on this machine on 2026-08-21 over a 6504-sample run-down from
    /// 77.8 % to 12.0 %, taking the lightest-load sample in each 2.5-point bin so
    /// the table sits near open circuit rather than recording that day's load,
    /// then pooled monotonically. Slopes: 26.8 mV per point above 45 %, 12.8
    /// across the 20-45 % plateau, 19.7 into the knee below 22 %.
    ///
    /// > **The bottom is extrapolated, and it is the weak point.** The run
    /// > stopped at 12 % (plugged in), so 0-12.5 % is a straight run-out along
    /// > the knee slope, clamped at 3.0 V per cell. A real cell falls faster
    /// > than that, so this UNDERSTATES the correction. It is bounded: the
    /// > unmeasured stretch is 17 % of the integral at 70 % SoC and 24 % at
    /// > 50 %, so a 3 % error down there moves the correction by 0.5-0.7 %.
    /// > It grows to 62 % of the integral at 20 % SoC — where the correction
    /// > itself has shrunk to under 2 %, so the absolute error stays small
    /// > either way. A run to actual shutdown replaces this paragraph.
    static let dischargeShape: [(soc: Double, v: Double)] = [
        (12.5, 0.95388), (15.0, 0.95853), (17.5, 0.96240), (20.0, 0.96640),
        (22.5, 0.96640), (25.0, 0.97212), (27.5, 0.97419), (30.0, 0.97445),
        (32.5, 0.97746), (35.0, 0.98004), (37.5, 0.98374), (40.0, 0.98804),
        (42.5, 0.98985), (45.0, 0.99380), (47.5, 0.99441), (50.0, 1.00000),
        (52.5, 1.00551), (55.0, 1.00654), (57.5, 1.01523), (60.0, 1.02031),
        (62.5, 1.02986), (65.0, 1.03648), (67.5, 1.03665), (70.0, 1.04500),
        (72.5, 1.04982), (75.0, 1.06178), (77.5, 1.06565),
    ]

    /// Relative voltage at a state of charge; linear between bins and along the
    /// end slopes outside them, floored so the extrapolation can never reach
    /// zero and turn the integral below into a division by nothing.
    /// Least-squares slope of `dischargeShape` from 45 % to the top of the
    /// table, per point of charge: the extrapolation above the measured range.
    static let upperSlope: Double = {
        let pts = dischargeShape.filter { $0.soc >= 45 }
        let n = Double(pts.count)
        let mx = pts.reduce(0) { $0 + $1.soc } / n
        let my = pts.reduce(0) { $0 + $1.v } / n
        let sxy = pts.reduce(0) { $0 + ($1.soc - mx) * ($1.v - my) }
        let sxx = pts.reduce(0) { $0 + ($1.soc - mx) * ($1.soc - mx) }
        return sxy / sxx
    }()

    static func relativeVoltage(atSoCPercent soc: Double) -> Double {
        let c = dischargeShape
        let s = min(100, max(0, soc))
        if s <= c[0].soc {
            let m = (c[1].v - c[0].v) / (c[1].soc - c[0].soc)
            // 3.0 V/cell against this pack's 3.86 V/cell nominal — the
            // conventional lithium cutoff, as a fraction of the 50 % anchor.
            return max(0.774, c[0].v + m * (s - c[0].soc))
        }
        let n = c.count - 1
        if s >= c[n].soc {
            // The least-squares slope of the upper curve (45-77.5 %), not the
            // last bin's. That final step is the flattest on the table (0.00155
            // a point against 0.00231 fitted), so running it out to 100 % read
            // the top of the pack as flatter than it is and left the correction
            // ~1.4 % optimistic at a full charge — about 8 minutes of 10 hours.
            // It never mattered on the machine the curve came from, which holds
            // at an 80 % limit; a pack that charges to 100 % lives up here.
            return c[n].v + Self.upperSlope * (s - c[n].soc)
        }
        var i = 0
        while i + 1 < c.count && c[i + 1].soc < s { i += 1 }
        let f = (s - c[i].soc) / (c[i + 1].soc - c[i].soc)
        return c[i].v + f * (c[i + 1].v - c[i].v)
    }

    /// How much shorter the honest projection is than `charge / rate`.
    ///
    /// `V̄_remaining / V_now`, which is the whole correction: the true time is
    /// `(1/P)∫V dQ` over the charge that remains, and `charge / rate` is
    /// `Q·V_now/P`. Always ≤ 1 — a pack whose voltage falls cannot outlast a
    /// constant-current projection of itself.
    ///
    /// STATE-DEPENDENT, and that is the result rather than an inconvenience.
    /// Integrating the measured curve: 7.1 % at 78 %, 5.9 % at 70 %, 3.2 % at
    /// 50 %, 1.8 % at 20 %. At a high state of charge most of the steep upper
    /// curve still lies ahead; near empty only the flat plateau does. So a
    /// single constant cannot express this, which is why the table above exists
    /// rather than one more number.
    ///
    /// Clamped to 1 at the top: the correction is a physical statement about
    /// what the pack will do, and a value above 1 would be this arithmetic
    /// disagreeing with itself rather than a pack that gains voltage.
    public static func constantPowerFactor(atSoCPercent soc: Double) -> Double {
        let s = min(100, max(0, soc))
        guard s > 0 else { return 1 }
        let vNow = relativeVoltage(atSoCPercent: s)
        guard vNow > 0 else { return 1 }
        // Trapezoid over the charge that remains. 64 steps: the curve is
        // piecewise linear over 27 bins, so this resolves it and costs nothing
        // at the 2 s cadence a renderer calls it.
        let n = 64
        var sum = 0.0
        for j in 0...n {
            let w = (j == 0 || j == n) ? 0.5 : 1.0
            sum += w * relativeVoltage(atSoCPercent: s * Double(j) / Double(n))
        }
        let mean = sum / Double(n)
        let f = mean / vNow
        return f.isFinite ? min(1, max(0.5, f)) : 1
    }
}
