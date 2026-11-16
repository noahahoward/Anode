import Foundation

/// A row of macOS's Sound panel that picks an output: its name, whether it is the current one, and the battery text the
/// panel shows under an AirPods row.
public struct AppleDeviceRow: Equatable {
    public var name: String
    public var isSelected: Bool
    public var batteryText: String?
    public init(name: String, isSelected: Bool, batteryText: String? = nil) {
        self.name = name; self.isSelected = isSelected; self.batteryText = batteryText
    }
}

/// A row that belongs to one section of an expanded device: a listening mode, a Spatial Audio state, or a Conversation
/// Awareness state.
public struct AppleChoiceRow: Equatable {
    public var section: String
    public var title: String
    public var isOn: Bool
    public var enabled: Bool
    public var device: String
    public init(section: String, title: String, isOn: Bool, enabled: Bool, device: String) {
        self.section = section; self.title = title; self.isOn = isOn; self.enabled = enabled; self.device = device
    }
}

/// What macOS's own Sound panel says, read from its Accessibility tree. This is the only way to see, and press, the rows
/// macOS keeps to itself: the AirPods listening mode, Spatial Audio, Conversation Awareness, the AirPlay speakers.
///
/// A tree that does not look like the panel (a macOS update changed an id or a label) gives no rows at all, never a wrong
/// row: nothing here guesses.
public struct AppleSoundPanel: Equatable {
    public var volume: Double?
    public var devices: [AppleDeviceRow] = []
    public var listening: [AppleChoiceRow] = []
    public var spatial: [AppleChoiceRow] = []
    public var conversation: [AppleChoiceRow] = []
    /// The device whose disclosure triangle is open, if any.
    public var expandedDevice: String?
    /// The buttons at the bottom ("<device> Settings…", "Sound Settings…").
    public var settingsButtons: [String] = []

    public static let volumeSliderID = "controlcenter-volume-slider"
    public static let devicePrefix = "sound-device-"
    public static let listeningHeading = "Listening Mode"
    public static let spatialHeading = "Spatial Audio"
    public static let conversationHeading = "Conversation Awareness"

    public init() {}

    public static func parse(_ root: AXNode) -> AppleSoundPanel {
        var panel = AppleSoundPanel()
        var section = ""
        for node in root.flattened {
            switch node.role {
            case "AXHeading":
                section = node.description
            case "AXSlider" where node.identifier == volumeSliderID:
                panel.volume = Double(node.value)
            case "AXDisclosureTriangle" where node.identifier.hasPrefix(devicePrefix) && node.value == "1":
                panel.expandedDevice = String(node.identifier.dropFirst(devicePrefix.count))
            case "AXButton" where node.description.hasSuffix("Settings…"):
                panel.settingsButtons.append(node.description)
            case "AXCheckBox" where node.identifier.hasPrefix(devicePrefix):
                let name = String(node.identifier.dropFirst(devicePrefix.count))
                let on = node.value == "1"
                if node.description == name {
                    panel.devices.append(AppleDeviceRow(name: name, isSelected: on))
                    section = ""
                } else if node.description.hasPrefix(name + ", ") {
                    panel.devices.append(AppleDeviceRow(name: name, isSelected: on,
                                                        batteryText: String(node.description.dropFirst(name.count + 2))))
                    section = ""
                } else if name == panel.expandedDevice {
                    // A choice only counts when it belongs to the device whose section is open: a device row whose label
                    // differs from its id (a speaker's name is whatever it calls itself) is never read as one.
                    let row = AppleChoiceRow(section: section, title: node.description, isOn: on, enabled: node.enabled, device: name)
                    switch section {
                    case listeningHeading: panel.listening.append(row)
                    case spatialHeading: panel.spatial.append(row)
                    case conversationHeading: panel.conversation.append(row)
                    default: break
                    }
                }
            default: break
            }
        }
        return panel
    }
}
