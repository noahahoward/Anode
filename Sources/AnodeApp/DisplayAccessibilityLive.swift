import AppKit
import PowerKit

extension DisplayAccessibility {

    /// Set by the tests; nil in the app.
    static var override: DisplayAccessibility?

    /// What the person has turned on in System Settings > Accessibility > Display, now.
    static var current: DisplayAccessibility {
        if let override { return override }
        let w = NSWorkspace.shared
        return DisplayAccessibility(reduceTransparency: w.accessibilityDisplayShouldReduceTransparency,
                                    increaseContrast: w.accessibilityDisplayShouldIncreaseContrast,
                                    reduceMotion: w.accessibilityDisplayShouldReduceMotion)
    }

    /// Posted (by the workspace) when any of the three changes.
    static let changed = NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
}

/// The panel's plain fill under Reduce Transparency: dark in the dark appearance, near-white in the light one, whichever appearance
/// the menu is in when it is drawn.
final class SolidPanelView: NSView {
    private static let fill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.96, alpha: 1)
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = Self.fill.cgColor } }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}
