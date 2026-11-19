import AppKit
import PowerKit

/// Joins Clipboard History to the app: the real pasteboard, the real panel, the real shortcut listener, and the notices of the
/// screens sleeping and the session locking. With the setting off the controller holds nothing but an observer.
enum ClipboardHistoryRuntime {

    private static let shortcutOwner = "clipboardHistory"

    static func live() -> ClipboardHistoryController {
        let folder = (AnodeFiles.applicationSupport ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
            .appendingPathComponent("Anode", isDirectory: true)
            .appendingPathComponent(ClipboardStore.folderName, isDirectory: true)
        let store = ClipboardStore(directory: folder, limits: ClipboardHistoryController.limits(from: .shared))
        let controller = ClipboardHistoryController(
            settings: .shared, store: store, presenter: LazyClipboardPanel(),
            changeCount: { RealClipboard.changeCount }, types: { RealClipboard.types() },
            read: { RealClipboard.read(maxBytes: $0) },
            writePasteboard: { RealClipboard.write($0, plainTextOnly: $1) },
            sendPaste: { PasteKeystroke.paste() },
            accessibility: { AccessibilityAccess.isTrusted },
            frontApp: {
                let app = NSWorkspace.shared.frontmostApplication
                return (app?.bundleIdentifier, app?.localizedName)
            },
            // The app a copy says it came from, when it says: used to label the entry, and judged by the rules as well as the app in front
            // (never instead of it: it is only what the copying app says of itself).
            declaredSource: {
                guard let id = RealClipboard.declaredSource() else { return nil }
                return (id, ClipboardAppNames.name(for: id))
            },
            restoreFront: { bringBack($0) },
            startTimer: { interval, tolerance, tick in
                let timer = Timer(timeInterval: interval, repeats: true) { _ in tick() }
                timer.tolerance = tolerance
                RunLoop.main.add(timer, forMode: .common)
                return { timer.invalidate() }
            },
            registerShortcut: { fire in
                KeybindCenter.shared.register(owner: shortcutOwner, commands: ShortcutCommands.clipboard) { _ in fire() }
            },
            unregisterShortcut: { KeybindCenter.shared.unregister(owner: shortcutOwner) },
            schedule: { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) },
            accessDescription: { RealClipboard.accessDescription() })
        ClipboardHistoryController.current = controller
        watchScreenAndSession(controller)
        return controller
    }

    /// The app that was in front is in front again. Closing a key panel can hand "key" on to a window of Anode's own and bring it
    /// forward (measured on the Sound menu), over the very app being pasted into; so this looks at once and again a moment later.
    static func bringBack(_ bundleID: String?) {
        guard let bundleID else { return }
        func restore() {
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier != bundleID,
                  let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return }
            if #available(macOS 14.0, *) { app.activate() } else { app.activate(options: []) }
        }
        restore()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { restore() }
    }

    /// Nobody is copying while the screens are asleep or the session is locked, and a timer would only keep the Mac awake.
    private static func watchScreenAndSession(_ controller: ClipboardHistoryController) {
        let ws = NSWorkspace.shared.notificationCenter
        let pairs: [(Notification.Name, Bool, Bool)] = [   // (name, isSleep, value)
            (NSWorkspace.screensDidSleepNotification, true, true), (NSWorkspace.screensDidWakeNotification, true, false),
            (NSWorkspace.willSleepNotification, true, true), (NSWorkspace.didWakeNotification, true, false),
            (NSWorkspace.sessionDidResignActiveNotification, false, true), (NSWorkspace.sessionDidBecomeActiveNotification, false, false),
        ]
        for (name, isSleep, value) in pairs {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak controller] _ in
                if isSleep { controller?.setScreensAsleep(value) } else { controller?.setLocked(value) }
            }
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak controller] _ in
            controller?.setLocked(true)
        }
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak controller] _ in
            controller?.setLocked(false)
        }
    }
}

/// The panel, made when it is first opened. With the feature off (the usual case) no window, field editor or glass is ever made, and
/// nothing in making them can stop the app from launching.
final class LazyClipboardPanel: ClipboardPresenting {
    private var panel: ClipboardPanel?

    var isOpen: Bool { panel?.isOpen ?? false }

    func show(controller: ClipboardHistoryController) {
        if panel == nil { panel = ClipboardPanel() }
        panel?.show(controller: controller)
    }

    func refresh() { panel?.refresh() }

    func hide(completion: @escaping () -> Void) {
        guard let panel else { completion(); return }
        panel.hide(completion: completion)
    }
}
