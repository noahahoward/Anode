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

    public init(powerSource: String, modes: [EnergyMode], energyApps: [EnergyApp]) {
        self.powerSource = powerSource; self.modes = modes; self.energyApps = energyApps
    }

    public var selectedModeID: String? { modes.first { $0.isSelected }?.id }
}
