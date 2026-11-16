import Foundation

/// What kind of thing an output is, which decides its glyph in the menu and in the menu bar.
public enum OutputKind: Equatable {
    case speakers, airpodsPro, airpods, headphones, hifi, display, airplay, other

    /// The kind from what Core Audio and IOKit say. A Bluetooth product id beats the name, since the name is whatever the
    /// owner called their AirPods.
    public static func guess(name: String, transport: String, productID: Int? = nil) -> OutputKind {
        switch productID {
        case 8228?, 8206?: return .airpodsPro      // AirPods Pro 2, AirPods Pro
        case 8194?, 8207?, 8211?, 8202?: return .airpods
        default: break
        }
        let n = name.lowercased()
        if transport == "bltn" { return .speakers }
        if n.contains("airpods") { return n.contains("pro") ? .airpodsPro : .airpods }
        if transport == "blue" { return .headphones }
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
