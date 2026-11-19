import AppKit
import PowerKit

// ── Said once, when a feature that watches the keyboard or the mouse is turned on ───────────────────────
//
// macOS 27.3 and later shows "Accessing all apps" for Anode in the menu bar while Anode holds an event tap (see `PrivacyIndicatorNote`).
// The sentence at the end of each feature's description in Beta Features is in bold, and a person who turns the feature on is told once
// more, in a box, so the indicator is not a surprise: a tester read it as something Anode does beyond the feature. Once for each feature
// (the answer is kept in the settings' own suite); a feature turned off and on again does not ask again.

enum PrivacyNotice {

    static let suiteName = "com.anode.settings"

    static func key(for feature: String) -> String { "anode.privacyNoticeSeen." + feature }

    /// Says it if this feature has not said it yet, and notes that it did. `summary` is the feature's description, which holds the
    /// sentence; a feature whose description has none says nothing. `present` shows the box (a test replaces it).
    static func showOnce(feature: String, summary: String,
                         defaults: UserDefaults? = UserDefaults(suiteName: suiteName),
                         present: (NSAlert) -> Void = { _ = $0.runModal() }) {
        guard let sentence = PrivacyIndicatorNote.sentence(in: summary), let defaults, !defaults.bool(forKey: key(for: feature)) else { return }
        defaults.set(true, forKey: key(for: feature))
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "macOS will show \u{201C}Accessing all apps\u{201D} for Anode"
        alert.informativeText = sentence
        alert.addButton(withTitle: "OK")
        present(alert)
    }
}

extension BetaFeature {
    /// Called when the person turns the feature on.
    func saysItsPrivacyNote() { PrivacyNotice.showOnce(feature: title, summary: summary) }
}
