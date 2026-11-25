import Foundation

/// Where a number on the hardware view came from.
///
/// `real` is read from the machine. `estimate` is worked out (a model, or a
/// figure macOS itself estimates) and the UI marks it so. `example` is a
/// stand-in that is not this Mac's reading; the live view never produces one,
/// the case exists so a mock-up or a preview can say so.
public enum Provenance: Equatable {
    case real
    case estimate
    case example
}

/// A reading and how it was obtained. A nil `value` means "not available" and
/// is shown as "—", never as zero.
public struct Tagged<T> {
    public var value: T?
    public var provenance: Provenance

    public init(value: T?, provenance: Provenance) {
        self.value = value
        self.provenance = provenance
    }

    public static func real(_ value: T?) -> Tagged<T> {
        Tagged(value: value, provenance: .real)
    }

    public static func estimate(_ value: T?) -> Tagged<T> {
        Tagged(value: value, provenance: .estimate)
    }
}

extension Tagged: Equatable where T: Equatable {}

public struct FanReading: Equatable {
    public var index: Int
    public var rpm: Double
    public var minRPM: Double
    public var maxRPM: Double
    public var targetRPM: Double?
    /// True when a manual target is set for this fan (see `manualTargets`).
    public var isManual: Bool
}

public struct MemoryReading: Equatable {
    public var app: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    public var free: UInt64
    public var total: UInt64
    /// The kernel's own level: 1 normal, 2 warning, 4 critical. nil when the
    /// kernel did not answer.
    public var pressure: Int32?
    public var swapBytes: Tagged<UInt64>
}

public struct StorageReading: Equatable {
    public var freeBytes: UInt64?
    public var totalBytes: UInt64?
    public var readBPS: Double?
    public var writeBPS: Double?
    public var smartTempC: Double?
    public var wearPercent: Int?
    public var spare: Int?
    public var bytesWritten: UInt64?
}

/// What the pack is doing, in words the battery detail can print.
public enum BatteryChargeState: Equatable {
    case charging
    /// On the adapter, at full charge.
    case full
    /// On the adapter, not charging, and not full (a charge limit, or a pause).
    case pluggedNotCharging
    case discharging
}

public struct BatteryReading: Equatable {
    public var percent: Int
    public var tempC: Double?
    /// Pack current in amps; positive while charging, negative while
    /// discharging.
    public var amps: Double
    public var isCharging: Bool
    public var state: BatteryChargeState
    /// macOS's own estimate. Minutes to full while charging, to empty
    /// otherwise.
    public var timeRemainingMin: Tagged<Int>
    /// Capacity against new, in percent (0...100). nil when the pack's design
    /// capacity is not known.
    public var health: Double?
    public var cycles: Int
    /// nil when the caller did not supply it; never guessed.
    public var designCycles: Int?
    /// What the whole Mac uses, from the gas gauge.
    public var systemDrawW: Tagged<Double>
}

public struct AdapterReading: Equatable {
    public var ratedW: Double?
    /// What the adapter is putting in. Always an estimate.
    public var drawnW: Tagged<Double>
    public var isCharging: Bool
}

public struct DisplayReading: Equatable {
    /// 0...1, nil when macOS would not say.
    public var brightness: Double?
    /// `real` only when the backlight rail was identified on this Mac.
    public var watts: Tagged<Double>
}

/// Everything the hardware view shows, bound once per tick from the app's own
/// readings. A plain value: no AppKit, no colours, nothing that reads the
/// machine itself. `make` is pure.
public struct HardwareReadings {
    public var fans: [FanReading]
    /// False when this tick did not sweep the sensors: "no fans listed" then
    /// means "not measured", and every temperature is nil.
    public var fansMeasured: Bool
    public var cpuTemp: Tagged<Double>
    public var gpuTemp: Tagged<Double>
    /// How many die sensors the means are taken over; 0 when not known.
    public var cpuSensorCount: Int
    public var gpuSensorCount: Int
    public var memory: MemoryReading?
    public var network: (down: Double, up: Double)?
    /// The busiest link's name, for the Wi-Fi detail's Interface row.
    public var networkInterface: String?
    public var storage: StorageReading?
    public var battery: BatteryReading?
    public var adapter: AdapterReading?
    public var display: DisplayReading?
    /// Whole-Mac draw from the gas gauge. Present on a desktop too, where it is
    /// the power-supply figure.
    public var systemW: Tagged<Double>
    public var helperInstalled: Bool

    public init(fans: [FanReading] = [],
                fansMeasured: Bool = true,
                cpuTemp: Tagged<Double> = .real(nil),
                gpuTemp: Tagged<Double> = .real(nil),
                cpuSensorCount: Int = 0,
                gpuSensorCount: Int = 0,
                memory: MemoryReading? = nil,
                network: (down: Double, up: Double)? = nil,
                networkInterface: String? = nil,
                storage: StorageReading? = nil,
                battery: BatteryReading? = nil,
                adapter: AdapterReading? = nil,
                display: DisplayReading? = nil,
                systemW: Tagged<Double> = .real(nil),
                helperInstalled: Bool = false) {
        self.fans = fans
        self.fansMeasured = fansMeasured
        self.cpuTemp = cpuTemp
        self.gpuTemp = gpuTemp
        self.cpuSensorCount = cpuSensorCount
        self.gpuSensorCount = gpuSensorCount
        self.memory = memory
        self.network = network
        self.networkInterface = networkInterface
        self.storage = storage
        self.battery = battery
        self.adapter = adapter
        self.display = display
        self.systemW = systemW
        self.helperInstalled = helperInstalled
    }
}

extension HardwareReadings {

    /// Binds the app's readings to what the view shows. Pure.
    ///
    /// Provenance: temperatures are `real` (the mean of the die sensors); the
    /// adapter's drawn power and the battery's time remaining are `estimate`;
    /// display watts are `real` only when `displayIsMeasured`. With
    /// `sensorsSampled == false` the fans are unmeasured and the temperatures
    /// nil, because the snapshot's empty values then mean "skipped", not
    /// "none".
    ///
    /// Parameters beyond the brief's list, all defaulted: `volume` (free and
    /// total space of the startup volume, which no snapshot carries),
    /// `cpuSensorCount` and `gpuSensorCount` (how many sensors the means are
    /// over) and `designCycles` (the pack's rated cycles; the battery state does
    /// not carry it).
    public static func make(system: SystemMetrics.Snapshot,
                            power: PowerMonitor.Snapshot?,
                            swapBytes: UInt64?,
                            brightness: Double?,
                            nvme: NVMeHealth.Sample?,
                            helperInstalled: Bool,
                            manualTargets: [Int: Double],
                            volume: (freeBytes: UInt64, totalBytes: UInt64)? = nil,
                            cpuSensorCount: Int = 0,
                            gpuSensorCount: Int = 0,
                            designCycles: Int? = nil) -> HardwareReadings {

        let sampled = system.sensorsSampled

        let fans: [FanReading] = sampled ? system.fans.map { f in
            FanReading(index: f.index,
                       rpm: f.currentRPM,
                       minRPM: f.minRPM,
                       maxRPM: f.maxRPM,
                       targetRPM: manualTargets[f.index] ?? f.targetRPM,
                       isManual: manualTargets[f.index] != nil)
        } : []

        let cpuT: Double? = sampled ? finite(system.cpuTemperature) : nil
        let gpuT: Double? = sampled ? finite(system.gpuTemperature) : nil

        let memory: MemoryReading? = system.memory.map { m in
            MemoryReading(app: m.app, wired: m.wired, compressed: m.compressed,
                          free: m.free, total: m.total, pressure: m.pressureLevel,
                          swapBytes: .real(swapBytes))
        }

        let network: (down: Double, up: Double)? = system.network.map {
            (down: $0.bytesInPerSec, up: $0.bytesOutPerSec)
        }

        var storage: StorageReading? = nil
        if system.disk != nil || volume != nil || nvme != nil {
            storage = StorageReading(freeBytes: volume?.freeBytes,
                                     totalBytes: volume?.totalBytes,
                                     readBPS: system.disk?.bytesReadPerSec,
                                     writeBPS: system.disk?.bytesWrittenPerSec,
                                     smartTempC: nvme?.temperatureC,
                                     wearPercent: nvme.map { Int($0.percentageUsed) },
                                     spare: nvme.map { Int($0.availableSpare) },
                                     bytesWritten: nvme?.bytesWritten)
        }

        // Whole-system draw: the SMC PSTR reading (median, gain-corrected, every tick), and the
        // gas gauge's 60 s average when PSTR is unavailable or not a finite number. Both are real measurements.
        let systemW: Tagged<Double> = .real(finite(power?.smcTotal_W) ?? finite(power?.measured_W))

        var battery: BatteryReading? = nil
        var adapter: AdapterReading? = nil
        if let p = power, let s = p.state {
            let chargeState: BatteryChargeState
            if s.isCharging {
                chargeState = .charging
            } else if s.onAC {
                chargeState = (s.fullyCharged || s.percent >= 100) ? .full : .pluggedNotCharging
            } else {
                chargeState = .discharging
            }
            let health: Double? = p.scale.designCapacity_mAh > 0 ? p.scale.health * 100 : nil
            battery = BatteryReading(percent: s.percent,
                                     tempC: finite(s.temperature_C),
                                     amps: Double(s.amperage_mA) / 1000,
                                     isCharging: s.isCharging,
                                     state: chargeState,
                                     timeRemainingMin: .estimate(s.timeRemaining_min),
                                     health: health,
                                     cycles: s.cycleCount,
                                     designCycles: designCycles,
                                     systemDrawW: systemW)

            if s.onAC || s.adapterPresent {
                let drawn: Double? = {
                    guard s.onAC, let mW = s.adapterInput_mW, mW.isFinite, mW > 0 else { return nil }
                    return mW / 1000
                }()
                adapter = AdapterReading(ratedW: s.adapterWatts,
                                         drawnW: .estimate(drawn),
                                         isCharging: s.isCharging)
            }
        }

        var display: DisplayReading? = nil
        let displayW = finite(power?.display_W)
        if brightness != nil || displayW != nil {
            display = DisplayReading(
                brightness: brightness,
                watts: Tagged(value: displayW,
                              provenance: (power?.displayIsMeasured ?? false) ? .real : .estimate))
        }

        return HardwareReadings(fans: fans,
                                fansMeasured: sampled,
                                cpuTemp: .real(cpuT),
                                gpuTemp: .real(gpuT),
                                cpuSensorCount: cpuSensorCount,
                                gpuSensorCount: gpuSensorCount,
                                memory: memory,
                                network: network,
                                networkInterface: system.network?.interfaces.first?.name,
                                storage: storage,
                                battery: battery,
                                adapter: adapter,
                                display: display,
                                systemW: systemW,
                                helperInstalled: helperInstalled)
    }

    private static func finite(_ v: Double?) -> Double? {
        guard let v = v, v.isFinite else { return nil }
        return v
    }
}
