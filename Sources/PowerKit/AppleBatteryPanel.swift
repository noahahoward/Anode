import Foundation

/// What macOS's own Battery panel says, read from its Accessibility tree: the only way to see the Energy Mode that is in force and
/// the apps it lists. A tree that does not look like the panel (a macOS update changed an id or a label) gives no rows at all, never
/// a wrong row: nothing here guesses.
public struct AppleBatteryPanel: Equatable, Codable {
    public struct Mode: Equatable, Codable {
        public var id: String
        public var title: String
        public var isSelected: Bool
        public init(id: String, title: String, isSelected: Bool) { self.id = id; self.title = title; self.isSelected = isSelected }
    }

    /// The word after "Power Source: " (`Battery`, `Power Adapter`).
    public var powerSource: String?
    public var modes: [Mode] = []
    /// The names under "Using Significant Energy".
    public var energyApps: [String] = []
    /// The button at the bottom ("Battery Settings…").
    public var settingsTitle: String?

    public static let headerID = "battery-header"
    public static let modePrefix = "energy-mode-"
    public static let powerSourcePrefix = "Power Source: "
    public static let significantEnergyHeading = "Using Significant Energy"

    public init() {}

    /// Whether the tree is the Battery panel: its header is there and it has the energy modes.
    public var looksLikeTheBatteryPanel: Bool { powerSource != nil && !modes.isEmpty }

    public static func parse(_ root: AXNode) -> AppleBatteryPanel {
        var panel = AppleBatteryPanel()
        var section = ""
        for node in root.flattened {
            switch node.role {
            case "AXStaticText" where node.identifier == headerID && node.value.hasPrefix(powerSourcePrefix):
                panel.powerSource = String(node.value.dropFirst(powerSourcePrefix.count))
            case "AXHeading":
                section = node.description
            case "AXCheckBox" where node.identifier.hasPrefix(modePrefix):
                panel.modes.append(Mode(id: String(node.identifier.dropFirst(modePrefix.count)), title: node.description, isSelected: node.value == "1"))
            case "AXButton" where node.description.hasSuffix("Settings…"):
                panel.settingsTitle = node.description
                section = ""
            case "AXButton" where section == significantEnergyHeading && node.identifier.isEmpty && !node.description.isEmpty:
                panel.energyApps.append(node.description)
            default: break
            }
        }
        // Nothing of a tree that is not this panel is kept.
        return panel.looksLikeTheBatteryPanel ? panel : AppleBatteryPanel()
    }
}

extension BatteryMenuModel {
    /// The menu as macOS's panel shows it.
    public init(apple: AppleBatteryPanel) {
        self.init(powerSource: apple.powerSource ?? "",
                  modes: apple.modes.map { EnergyMode(id: $0.id, title: $0.title, isSelected: $0.isSelected) },
                  energyApps: apple.energyApps.map { EnergyApp(name: $0) })
    }
}
