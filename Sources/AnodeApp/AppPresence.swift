import AppKit
import PowerKit

/// Where Anode is allowed to be invisible, and where it is not.
///
/// ── Why there is no "headless at login, windowed by hand" ────────────────────
///
/// The obvious design is to launch with no window when the OS starts us at login
/// and with a window when the user double-clicks us, so nobody ever opens the app
/// and appears to get nothing. It is not implementable on this platform, and the
/// check was made rather than assumed.
///
/// MEASURED on this machine, against Rectangle — a real `SMAppService.mainApp`
/// login item, started 32 s after boot with ppid 1 — versus a hand-launched app:
///
///   argv           login:  /Applications/Rectangle.app/Contents/MacOS/Rectangle
///                  manual: /…/Anode.app/Contents/MacOS/AnodeApp
///                  Identical shape. No flag, no extra argument.
///   ppid           1 (launchd) in BOTH cases — Finder launches go through
///                  LaunchServices to launchd too, so the parent says nothing.
///   XPC_SERVICE_NAME
///                  login:  application.com.knollsoft.Rectangle.533133.533332
///                  manual: application.dev.anode.app.60075201.60075206
///                  Same `application.<bundle-id>.<n>.<n>` form either way.
///
/// So the login launch is indistinguishable from a manual one by every signal the
/// process can read about itself. (`NSApplicationLaunchIsDefaultLaunchKey` is the
/// remaining AppKit candidate; its value on a *login* launch cannot be verified
/// here without registering a real login item on the user's machine, so it is not
/// used. Guessing and being wrong looks exactly like the app failing to start,
/// which is the failure this whole design is trying to avoid.)
///
/// The honest alternative, and what this implements: ONE setting that applies to
/// every launch, stated as such in Preferences, with two ways back in that do not
/// depend on distinguishing anything — click a menu bar widget, or open the app
/// again (an already-running app gets `applicationShouldHandleReopen`, which
/// shows the window).
///
/// ── The invariant ───────────────────────────────────────────────────────────
///
/// The app must always present at least one thing the user can click: a menu bar
/// widget, a window, or a Dock tile. `AppMenu.showMainWindow` documents why this
/// is not negotiable — `.accessory` removes the application menu along with the
/// Dock tile, so an accessory app with no widgets and no window has no ⌘0, no
/// Dock icon, no menu and no Quit, and the only way to stop it is Activity
/// Monitor. That is the state these two functions exist to make unreachable.
enum AppPresence {

    /// Was this process started by the login agent rather than by a person?
    ///
    /// Read from our OWN argument, which the agent's plist puts there — see
    /// `LoginAgent.loginArgument` for why an argument and not the environment.
    static var openedAtLogin: Bool {
        CommandLine.arguments.contains(LoginAgent.loginArgument)
    }

    /// Does launch end with the main window on screen?
    ///
    /// `startInMenuBarOnly` is honoured only when there is a menu bar to start
    /// in. With widgets off it is overridden rather than obeyed, and Preferences
    /// says so beside the checkbox — an override the user cannot see is the same
    /// bug as a control that does nothing.
    ///
    /// AND ONLY AT LOGIN. The setting says "start in menu bar only", and starting
    /// is what a machine does at login; opening an app is what a person does on
    /// purpose. Applying it to both meant double-clicking Anode put nothing
    /// on screen — indistinguishable, from the user's side, from a launch that
    /// failed.
    ///
    /// The default when we cannot tell is to SHOW the window. An unwanted window
    /// at login is visible and one click from gone; a launch that appears to do
    /// nothing teaches people the app is broken.
    static func showsWindowAtLaunch(startInMenuBarOnly: Bool, widgetsEnabled: Bool,
                                    openedAtLogin: Bool = AppPresence.openedAtLogin) -> Bool {
        guard openedAtLogin else { return true }
        return !(startInMenuBarOnly && widgetsEnabled)
    }

    /// Activation policy to adopt at launch, before the first frame.
    ///
    /// Set once, up front, rather than `.regular` then `.accessory`: the second
    /// form flashes a Dock tile at every login for the state the user asked not
    /// to have.
    static func launchActivationPolicy(startInMenuBarOnly: Bool,
                                       widgetsEnabled: Bool,
                                       openedAtLogin: Bool = AppPresence.openedAtLogin)
        -> NSApplication.ActivationPolicy {
        showsWindowAtLaunch(startInMenuBarOnly: startInMenuBarOnly,
                            widgetsEnabled: widgetsEnabled,
                            openedAtLogin: openedAtLogin) ? .regular : .accessory
    }

    /// Activation policy once the window is closed or never opened.
    ///
    /// `.accessory` while widgets are on: an app whose only surface is the menu
    /// bar has no business holding a Dock tile, which is the whole point of
    /// `MainWindowController.hide()`. `.regular` while they are off, because the
    /// Dock tile is then the ONLY affordance left — clicking it reopens the
    /// window through `applicationShouldHandleReopen`. This is not the "fix" that
    /// `AppMenu.showMainWindow` warns against: that warning is about reinstating
    /// the tile while a widget already exists to click.
    /// Whether anyone can actually SEE the window, which is not the same as the
    /// window being open.
    ///
    /// `isVisible` stays true for a window buried under another app's, so a
    /// window left open behind a browser kept the app on the two-second cadence:
    /// building rows, re-sorting them, reconfiguring cells and redrawing a graph
    /// for a surface with nothing in front of it. AppKit already knows better —
    /// it stops calling `draw` on a fully covered window — and it will say so
    /// through `occlusionState` if asked.
    ///
    /// Being unfocused is NOT the same thing and deliberately does not count: a
    /// visible window beside the one you are typing in is still being read.
    ///
    /// Taken as two plain booleans so the rule can be tested without a window
    /// server, since neither `isVisible` nor `occlusionState` can be set by hand.
    static func windowIsWorthDrawing(isOpen: Bool, isOnScreen: Bool) -> Bool {
        isOpen && isOnScreen
    }

    static func policyWithWindowHidden(widgetsEnabled: Bool) -> NSApplication.ActivationPolicy {
        widgetsEnabled ? .accessory : .regular
    }
}
