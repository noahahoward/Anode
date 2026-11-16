import Foundation

/// A volume key as the keyboard reports it: a system-defined event whose `data1` holds the key in its top half and, in the next
/// byte, whether it went down (0xA) or up (0xB), and in its lowest bit whether it is the key repeating.
public struct MediaKeyEvent: Equatable {
    public enum Key: Equatable { case volumeUp, volumeDown, mute }
    public let key: Key
    public let isDown: Bool
    public let isRepeat: Bool

    /// Nil for any other key (brightness, play, next, keyboard light…): those are not Anode's to take.
    public init?(data1: Int) {
        switch (data1 & 0xFFFF0000) >> 16 {
        case 0: key = .volumeUp
        case 1: key = .volumeDown
        case 7: key = .mute
        default: return nil
        }
        let flags = data1 & 0xFFFF
        isDown = ((flags & 0xFF00) >> 8) == 0xA
        isRepeat = (flags & 0x1) != 0
    }
}

/// What the volume keys do to the level: one sixteenth a press, as macOS's own.
public enum VolumeKeys {
    public static let step = 1.0 / 16

    /// The level after `key`, or nil for the mute key (which is a switch, not a level).
    public static func next(volume: Double, key: MediaKeyEvent.Key) -> Double? {
        switch key {
        case .volumeUp: return min(1, volume + step)
        case .volumeDown: return max(0, volume - step)
        case .mute: return nil
        }
    }
}
