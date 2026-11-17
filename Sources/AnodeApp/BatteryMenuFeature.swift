import AppKit
import PowerKit

// ── Battery Menu (Beta Features) ────────────────────────────────────────────
//
// One switch: a click on macOS's own Battery icon opens Anode's Battery menu, a copy of macOS's. Everything it shows and does is
// the controller's; this section only turns it on and says what it needs.

final class BatteryMenuFeature: BetaFeature {

    let title = "Battery Menu"
    let summary = "Anode's own Battery menu, the same as macOS's: a click on macOS's Battery icon opens it instead. The Energy Modes "
                + "are read from macOS's own Battery panel and changed through it, so it needs Accessibility; the apps using significant "
                + "energy are Anode's own measurements. On macOS 27.3 and later macOS may show \"Accessing all apps\" under the menu bar "
                + "while Anode reads or presses that panel: that is macOS's own wording for Accessibility, and Anode only reads the "
                + "panel's text and presses its buttons."
    var layoutChanged: (() -> Void)?

    private let settings: Settings
    private let accessibility: () -> Bool
    private var observer: AnyObject?

    let enableCheckbox = NSButton(checkboxWithTitle: "Open Anode's Battery menu from macOS's Battery icon", target: nil, action: nil)
    let statusLabel = BetaFeaturesWindowController.wrapping("", color: .secondaryLabelColor)
    let accessibilityButton = NSButton(title: "Open Accessibility settings", target: nil, action: nil)

    init(settings: Settings = .shared, accessibility: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.settings = settings
        self.accessibility = accessibility
        observer = settings.observe(Settings.Key.batteryMenuEnabled) { [weak self] in self?.refresh() }
    }

    func makeView() -> NSView {
        enableCheckbox.target = self
        enableCheckbox.action = #selector(enableToggled)
        accessibilityButton.target = self
        accessibilityButton.action = #selector(openAccessibility)
        let stack = NSStackView(views: [enableCheckbox, statusLabel, accessibilityButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        refresh()
        return stack
    }

    @objc private func enableToggled() {
        let on = enableCheckbox.state == .on
        settings.batteryMenuEnabled = on
        if on && !accessibility() { AccessibilityAccess.request() }
        refresh()
    }

    @objc private func openAccessibility() { AccessibilityAccess.openSettings() }

    func refresh() {
        let on = settings.batteryMenuEnabled
        enableCheckbox.state = on ? .on : .off
        let trusted = accessibility()
        accessibilityButton.isHidden = !on || trusted
        if !on {
            statusLabel.stringValue = "Off."
        } else if !trusted {
            statusLabel.stringValue = "Needs Accessibility: until it is given, a click on the Battery icon opens macOS's own panel."
        } else {
            statusLabel.stringValue = "On."
        }
        statusLabel.textColor = on && !trusted ? .systemOrange : .secondaryLabelColor
        layoutChanged?()
    }
}
