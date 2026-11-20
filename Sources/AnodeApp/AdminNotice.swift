import AppKit
import PowerKit

/// The warning shown the moment someone turns on something that will run administrator commands.
///
/// A newly installed Anode runs no `sudo` and asks for no password. Where a feature does need either, the person is told
/// here, in the words of what will run, BEFORE it is on: a machine whose administrator commands are restricted or audited
/// should not find them first in a log. Declining leaves the feature off.
enum AdminNotice {

    static let keepAwakeTitle = "Keep Awake can run sudo commands"

    static let keepAwakeText = "Never Sleep keeps the Mac awake with macOS's own power assertion and needs no administrator "
        + "rights.\n\n"
        + "Always Stay Awake (lid closed) works by running \u{201C}sudo pmset -a disablesleep 1\u{201D} and \u{201C}\u{2026} 0\u{201D}. "
        + "The first time you use it, macOS asks for your administrator password once and Anode adds a rule, "
        + "/etc/sudoers.d/anode-keep-awake, that lets exactly those two commands run without a password. After that Anode "
        + "runs them in the background each time that mode starts and stops.\n\n"
        + "If your organisation restricts or audits sudo, those commands will appear in its logs and the rule may be "
        + "flagged. Turn Keep Awake on only if that is acceptable."

    static let turnOn = "Turn On"
    static let cancel = "Cancel"

    /// The alert, built apart from being shown so a test can read it without a modal.
    static func keepAwakeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = keepAwakeTitle
        alert.informativeText = keepAwakeText
        alert.alertStyle = .warning
        alert.addButton(withTitle: turnOn)
        alert.addButton(withTitle: cancel)
        return alert
    }

    /// True when the person chose to go ahead. Main thread.
    static func confirmKeepAwake() -> Bool {
        keepAwakeAlert().runModal() == .alertFirstButtonReturn
    }
}
