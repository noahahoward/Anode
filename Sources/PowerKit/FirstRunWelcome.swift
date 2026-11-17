import Foundation

/// The notice a newly installed Anode shows first, before the automatic-update question and the offer of the helper: what the app
/// may ask of the Mac, and what macOS will show when it does.
public enum FirstRunWelcome {

    /// Shown once, on the first launch of a fresh install. Not for someone who already uses Anode: they have answered the
    /// automatic-update question or been offered the helper (`helperOfferedForBuild` is the build the offer was last made for)
    /// in an earlier version.
    public static func isDue(welcomeSeen: Bool, autoUpdatePromptSeen: Bool, helperOfferedForBuild: String) -> Bool {
        !welcomeSeen && !autoUpdatePromptSeen && helperOfferedForBuild.isEmpty
    }

    public static let title = "Welcome to Anode!"

    public static let button = "Continue"

    public static let text =
        "Anode shows what is using your Mac's power. A few features need permissions, which macOS asks for the first time you turn "
        + "them on:\n\n"
        + "\u{2022} Accessibility, to read and press things in other apps. macOS 27.3 and later shows \u{201C}Accessing all apps\u{201D} in "
        + "the menu bar while Anode does: that is macOS's own notice.\n"
        + "\u{2022} Screen Recording, for window previews. Nothing is recorded or kept.\n"
        + "\u{2022} Your password, once, next: to install the Anode helper (Charge Control, fans, Ultra Low Power Mode).\n\n"
        + "All optional. Change any of it in System Settings \u{203A} Privacy & Security."
}
