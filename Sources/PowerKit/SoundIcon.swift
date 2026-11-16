import Foundation

/// What kind of thing an output is, which decides its glyph in the menu and in the menu bar.
public enum OutputKind: Equatable {
    case speakers, airpodsPro, airpods, airpodsMax, headphones, hifi, display, airplay, other

    /// The AirPods kinds, whose rows carry battery and listening-mode controls.
    public var isAirPods: Bool { self == .airpods || self == .airpodsPro || self == .airpodsMax }

    /// The kind from what Core Audio and IOKit say. A Bluetooth product id beats the name, since the name is whatever the
    /// owner called their AirPods.
    public static func guess(name: String, transport: String, productID: Int? = nil) -> OutputKind {
        switch productID {
        case 8228?, 8206?: return .airpodsPro      // AirPods Pro 2, AirPods Pro
        case 8202?: return .airpodsMax
        case 8194?, 8207?, 8211?: return .airpods
        default: break
        }
        let n = name.lowercased()
        func has(_ words: [String]) -> Bool { words.contains(where: n.contains) }
        let headWords = ["headphone", "headset", "earbuds", "earphone"]
        switch transport {
        case "bltn":
            // The jack with headphones in it keeps the built-in transport, and is not the laptop's speakers.
            return has(headWords) ? .headphones : .speakers
        case "hdmi", "dprt":
            return .display
        case "usb ":
            if has(headWords) { return .headphones }
            if has(["display", "monitor"]) { return .display }
            return .hifi
        default: break
        }
        if n.contains("airpods") { return n.contains("max") ? .airpodsMax : n.contains("pro") ? .airpodsPro : .airpods }
        if transport == "blue" {
            // Bluetooth is mostly headphones, but a speaker says so in its name.
            let speakerWords = ["speaker", "soundbar", "boom", "flip", "charge", "xtreme", "pulse", "soundlink", "sonos", "homepod",
                                "beosound", "emberton", "stanmore", "woburn"]
            return has(speakerWords) && !has(headWords) ? .hifi : .headphones
        }
        if transport == "airp" || transport == "ccwd" {
            if ["tv", "roku", "display", "monitor"].contains(where: n.contains) { return .display }
            if ["speaker", "receiver", "avr", "soundbar", "homepod", "denon", "stereo"].contains(where: n.contains) { return .hifi }
            return .airplay
        }
        return .other
    }
}

/// The glyph the Sound icon in the menu bar shows (an SF Symbol name). The volume bands are provisional until they are
/// measured against macOS's own icon.
public enum SoundIcon {
    public static func symbol(volume: Double, muted: Bool, output: OutputKind) -> String {
        switch output {
        case .airpodsPro: return "airpods.pro"
        case .airpods: return "airpods"
        case .airpodsMax: return "airpods.max"
        case .headphones: return "headphones"
        default:
            if muted { return "speaker.slash.fill" }
            if volume <= 0 { return "speaker.fill" }
            if volume <= 1.0 / 3 { return "speaker.wave.1.fill" }
            if volume <= 2.0 / 3 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        }
    }
}
