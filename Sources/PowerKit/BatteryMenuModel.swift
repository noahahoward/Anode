import Foundation

/// What the Battery menu shows: what macOS's panel says, and nothing of Anode's own yet.
public struct BatteryMenuModel: Equatable {
    public struct EnergyMode: Equatable {
        /// `automatic`, `low` or `high`: the end of macOS's `energy-mode-` identifier.
        public var id: String
        public var title: String
        public var isSelected: Bool
        public init(id: String, title: String, isSelected: Bool) { self.id = id; self.title = title; self.isSelected = isSelected }
    }

    public struct EnergyApp: Equatable {
        public var name: String
        public init(name: String) { self.name = name }
    }

    /// The word after "Power Source: ": `Battery` or `Power Adapter`.
    public var powerSource: String
    public var modes: [EnergyMode]
    /// The apps listed under "Using Significant Energy"; none leaves the section out.
    public var energyApps: [EnergyApp]

    // ── Anode's additions: each is present only while its own Beta feature is on ──

    /// The small gear that opens Beta Features.
    public var showsGear = false
    /// The charge limit row (Charge Control).
    public var chargeLimit: ChargeLimit?

    public struct ChargeLimit: Equatable {
        public var limit: Int
        public var range: ClosedRange<Int>
        public var softDrainRunning: Bool
        public var hardDrainRunning: Bool
        public init(limit: Int, range: ClosedRange<Int>, softDrainRunning: Bool, hardDrainRunning: Bool) {
            self.limit = limit; self.range = range; self.softDrainRunning = softDrainRunning; self.hardDrainRunning = hardDrainRunning
        }
    }

    public init(powerSource: String, modes: [EnergyMode], energyApps: [EnergyApp]) {
        self.powerSource = powerSource; self.modes = modes; self.energyApps = energyApps
    }

    public var selectedModeID: String? { modes.first { $0.isSelected }?.id }
}
