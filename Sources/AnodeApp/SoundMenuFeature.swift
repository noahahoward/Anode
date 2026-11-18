import AppKit
import PowerKit

// ── Sound Menu (Beta Features) ──────────────────────────────────────────────
//
// One switch: Anode's own Sound menu in the menu bar, a copy of macOS's. Everything it shows and does is the controller's;
// this section only turns it on and says what it is missing.

final class SoundMenuFeature: BetaFeature {

    let title = "Sound Menu"
    let summary = "Anode's own Sound menu, the same as macOS's, next to it in the menu bar. It works with or without macOS's "
                + "Sound icon: you can remove macOS's in System Settings, Control Center. Listening mode, Conversation "
                + "Awareness and AirPlay speakers go through macOS's own panel, so they need Accessibility. "
                + PrivacyIndicatorNote.text(while: "the option to open it from macOS's own Sound icon is on",
                                            watching: "mouse clicks, to catch the ones on that icon")
    var layoutChanged: (() -> Void)?

    private let settings: Settings
    private let accessibility: () -> Bool
    private let perAppVolumeAvailable: () -> Bool
    private var observers: [AnyObject] = []

    let enableCheckbox = NSButton(checkboxWithTitle: "Show Anode's Sound menu in the menu bar", target: nil, action: nil)
    let nativeIconCheckbox = NSButton(checkboxWithTitle: "Open it from macOS's own Sound icon instead (one icon, not two)", target: nil, action: nil)
    /// Each app's own volume, in an Apps section of the menu. Offered only once what it needs was verified on this Mac.
    let perAppCheckbox = NSButton(checkboxWithTitle: "Give each app its own volume (an Apps section in the menu)", target: nil, action: nil)
    let statusLabel = BetaFeaturesWindowController.wrapping("", color: .secondaryLabelColor)
    let accessibilityButton = NSButton(title: "Open Accessibility settings", target: nil, action: nil)

    init(settings: Settings = .shared, accessibility: @escaping () -> Bool = { AXIsProcessTrusted() },
         perAppVolumeAvailable: @escaping () -> Bool = { CoreAudioAppBackend.isReleaseReady }) {
        self.settings = settings
        self.accessibility = accessibility
        self.perAppVolumeAvailable = perAppVolumeAvailable
        observers.append(settings.observe(Settings.Key.soundMenuEnabled) { [weak self] in self?.refresh() })
        observers.append(settings.observe(Settings.Key.soundMenuUsesNativeIcon) { [weak self] in self?.refresh() })
        observers.append(settings.observe(Settings.Key.appAudioEnabled) { [weak self] in self?.refresh() })
    }

    func makeView() -> NSView {
        enableCheckbox.target = self
        enableCheckbox.action = #selector(enableToggled)
        nativeIconCheckbox.target = self
        nativeIconCheckbox.action = #selector(nativeIconToggled)
        perAppCheckbox.target = self
        perAppCheckbox.action = #selector(perAppToggled)
        accessibilityButton.target = self
        accessibilityButton.action = #selector(openAccessibility)
        let stack = NSStackView(views: [enableCheckbox, nativeIconCheckbox, perAppCheckbox, statusLabel, accessibilityButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        refresh()
        return stack
    }

    @objc private func enableToggled() {
        let on = enableCheckbox.state == .on
        settings.soundMenuEnabled = on
        if on && !accessibility() { AccessibilityAccess.request() }
        refresh()
    }

    @objc private func nativeIconToggled() {
        settings.soundMenuUsesNativeIcon = nativeIconCheckbox.state == .on
        refresh()
    }

    @objc private func perAppToggled() {
        settings.appAudioEnabled = perAppCheckbox.state == .on
        refresh()
    }

    @objc private func openAccessibility() { AccessibilityAccess.openSettings() }

    func refresh() {
        let on = settings.soundMenuEnabled
        enableCheckbox.state = on ? .on : .off
        nativeIconCheckbox.state = settings.soundMenuUsesNativeIcon ? .on : .off
        nativeIconCheckbox.isEnabled = on
        perAppCheckbox.isHidden = !perAppVolumeAvailable()
        perAppCheckbox.isEnabled = on
        perAppCheckbox.state = settings.appAudioEnabled ? .on : .off
        let trusted = accessibility()
        accessibilityButton.isHidden = !on || trusted
        if !on {
            statusLabel.stringValue = "Off."
        } else if !trusted {
            statusLabel.stringValue = "Needs Accessibility for the listening mode, Conversation Awareness and AirPlay rows. "
                + "The volume, the outputs and the battery readings work without it."
        } else {
            statusLabel.stringValue = "On."
        }
        statusLabel.textColor = on && !trusted ? .systemOrange : .secondaryLabelColor
        layoutChanged?()
    }
}
