import Foundation
import IOKit

/// The battery energy scale — the real "100%".
///
/// Deliberately NOT `mAh x instantaneous Voltage`: the readable `Voltage` is a
/// state-of-charge- and load-dependent terminal reading (~12.5 V at 80% SoC on a
/// 3S pack) and overstates full-charge energy by roughly 8%.
///
/// `nominalVoltage` is a seed. Once we have observed a clean on-battery window we
/// replace the whole scale with a measured `J/%` learned from the gas gauge, which
/// removes the assumed voltage entirely and tracks pack aging. See `calibrated(with:)`.
public struct BatteryScale {
    public let fullChargeCapacity_mAh: Double
    public let designCapacity_mAh: Double
    public let nominalVoltage_V: Double
    /// True once `joulesPerPercent` came from a measured discharge rather than the seed.
    public let isCalibrated: Bool

    /// 3S Li-ion pack nominal. Seed only — superseded by self-calibration.
    public static let seedNominalVoltage_V = 11.58

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
        let full = mAh(["FullChargeCapacity", "NominalChargeCapacity", "AppleRawMaxCapacity"]) ?? design

        return BatteryScale(
            fullChargeCapacity_mAh: full,
            designCapacity_mAh: design,
            nominalVoltage_V: BatteryScale.seedNominalVoltage_V,
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
            remainingCapacity_mAh: (data["RemainingCapacity"] as? NSNumber)?.doubleValue ?? 0,
            timeRemaining_min: sane,
            notChargingReason: int("NotChargingReason", charger),
            fullyCharged: props["FullyCharged"] as? Bool ?? false
        )
    }
}
