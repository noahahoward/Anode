import Foundation

/// What Anode says, in Beta Features, about macOS 27.3's privacy indicator.
///
/// The indicator (a pill in the menu bar, and a list under it) names the app an app is reading through Accessibility ("Accessing
/// Dock", "Accessing Finder and 2 more"). It says "Accessing all apps" for an app that holds an event tap, a watch on every key
/// press or mouse click (measured 2026-11-17: a tap that only counted did it, global mouse and key monitors and posting events did
/// not). Anode holds taps for its shortcuts, its switchers and the clicks on macOS's own Sound and Battery icons, so a feature that
/// keeps one running tells the person, with the true reason: the earlier wording blamed Accessibility.
public enum PrivacyIndicatorNote {

    /// One sentence for the end of a feature's summary. `condition` finishes "While …" ("this is on"); `watching` finishes
    /// "because Anode watches …" ("the keyboard for its shortcut").
    public static func text(while condition: String, watching: String) -> String {
        "While \(condition), macOS 27.3 and later shows \u{201C}Accessing all apps\u{201D} for Anode in the menu bar, because "
            + "Anode watches \(watching). macOS says that for any app that does."
    }
}
