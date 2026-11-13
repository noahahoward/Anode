import AppKit

// ── Ultra Low Power Mode: the black backdrop ────────────────────────────────
//
// While the mode is on, one plain black window per display sits over the desktop picture and the desktop icons and under every
// app window. With the other apps frozen and hidden, what is lit is then the kept app's windows, the menu bar and the Dock:
// measured, a fully black screen read about 0.5 to 0.7 W under the same screen showing ordinary content at the same
// brightness. What it saves in practice depends on how much of the screen the kept app covers.
//
// It is Anode's own window, so nothing is recorded: it goes when the mode ends, and with Anode if Anode is killed, and there
// is nothing to undo after a crash. It is set up like the live wallpaper's window (`DesktopWallpaperWindow`): click-through,
// never key, never main, on every Space.

protocol BackdropPresenting: AnyObject {
    func show()
    func hide()
}

/// One display's black window.
final class UltraBackdropWindow: NSWindow {

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(frame, display: false)
        // The backdrop closes it and lets it go itself: a window released by its own close is released twice.
        isReleasedWhenClosed = false
        level = LiveUltraBackdrop.level
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        animationBehavior = .none
        hasShadow = false
        isOpaque = true
        backgroundColor = .black
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        identifier = LiveUltraBackdrop.identifier
    }
}

final class LiveUltraBackdrop: BackdropPresenting {

    /// One above the desktop icons' level: over the picture (the system's own, and the live wallpaper's window, which is at the
    /// desktop-window level) and over the icons, and far under every app window.
    static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    static let identifier = NSUserInterfaceItemIdentifier("dev.anode.ultraBackdrop")

    /// One per screen, the screen's whole frame (not the part the menu bar and the Dock leave): the menu bar and the Dock are
    /// windows of their own, far above this one.
    static func frames(for screens: [NSRect]) -> [NSRect] { screens }

    /// What is up now: one window per screen while shown, none otherwise.
    private(set) var windows: [UltraBackdropWindow] = []

    private let screens: () -> [NSRect]
    private let present: (NSWindow) -> Void
    private let dismiss: (NSWindow) -> Void
    private let center: NotificationCenter
    private var observer: NSObjectProtocol?

    /// The closures are the system; tests replace them so no window is ever put on screen, and the center is theirs so that
    /// no real change of displays reaches them.
    init(screens: @escaping () -> [NSRect] = { NSScreen.screens.map(\.frame) },
         present: @escaping (NSWindow) -> Void = { $0.orderFrontRegardless() },
         dismiss: @escaping (NSWindow) -> Void = { $0.orderOut(nil); $0.close() },
         center: NotificationCenter = .default) {
        self.screens = screens
        self.present = present
        self.dismiss = dismiss
        self.center = center
    }

    /// Main thread. A second call while it is up does nothing.
    func show() {
        guard observer == nil else { return }
        // A display plugged in or out, or a change of its resolution, gives the screens other frames. Never a window that is
        // not at the screen's own size, and never a screen with none.
        observer = center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil) { [weak self] _ in
            let rebuild: () -> Void = { self?.rebuild() }
            if Thread.isMainThread { rebuild() } else { DispatchQueue.main.async(execute: rebuild) }
        }
        rebuild()
    }

    /// Main thread. Does nothing when it is not up.
    func hide() {
        guard let held = observer else { return }
        center.removeObserver(held)
        observer = nil
        closeWindows()
    }

    private func rebuild() {
        // A notice that was already on its way to the main thread when `hide` came finds it down, and builds nothing.
        guard observer != nil else { return }
        closeWindows()
        windows = Self.frames(for: screens()).map(UltraBackdropWindow.init(frame:))
        windows.forEach(present)
    }

    private func closeWindows() {
        let closing = windows
        windows = []
        closing.forEach(dismiss)
    }
}
