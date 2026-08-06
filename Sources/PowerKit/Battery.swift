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
}

public enum Battery {
    /// Raw property dictionary from the AppleSmartBattery IORegistry node.
    public static func properties() -> [String: Any]? {
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
    }

    public static func state() -> State? {
        guard let props = properties() else { return nil }
        let data = props["BatteryData"] as? [String: Any] ?? [:]

        func int(_ key: String, _ src: [String: Any]? = nil) -> Int {
            ((src ?? props)[key] as? NSNumber)?.intValue ?? 0
        }

        let raw = int("TimeRemaining")
        let sane = (raw > 0 && raw != 65535) ? raw : nil

        return State(
            percent: int("CurrentCapacity"),
            isCharging: props["IsCharging"] as? Bool ?? false,
            onAC: props["ExternalConnected"] as? Bool ?? false,
            cycleCount: int("CycleCount") != 0 ? int("CycleCount") : int("CycleCount", data),
            voltage_mV: int("Voltage"),
            amperage_mA: int("InstantAmperage") != 0 ? int("InstantAmperage") : int("Amperage"),
            remainingCapacity_mAh: (data["RemainingCapacity"] as? NSNumber)?.doubleValue ?? 0,
            timeRemaining_min: sane
        )
    }
}
