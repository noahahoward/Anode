import AppKit
import PowerKit

/// Owns the pieces that make live wallpapers run for the app: the controller, the source of its conditions, and the pause
/// shortcut. The source and the shortcut exist only while the feature is on; with it off there are no observers, no key listener,
/// no windows and no timers.
final class LiveWallpaperRuntime {

    let controller: LiveWallpaperController
    private let source: WallpaperConditionsSource
    private let settings: Settings
    private var token: AnyObject?
    private static let shortcutOwner = "liveWallpaper"

    init(settings: Settings = .shared, library: WallpaperLibrary = .shared, prefsStore: WallpaperPrefsStore = .shared,
         factory: WallpaperSurfaceFactory = RealWallpaperSurfaceFactory()) {
        self.settings = settings
        // The source reports to the controller and the controller reads the source: a weak holder joins them.
        final class Holder { weak var controller: LiveWallpaperController? }
        let holder = Holder()
        let source = WallpaperConditionsSource { refresh in holder.controller?.conditionsChanged(refresh: refresh) }
        self.source = source
        controller = LiveWallpaperController(settings: settings, library: library, prefsStore: prefsStore,
                                             displays: { DisplayInfo.current() }, factory: factory,
                                             conditions: { source.current() }, now: { Date() })
        holder.controller = controller
        controller.log = { FeatureLog.append("wallpaper.log", $0) }
        token = settings.observe(Settings.Key.liveWallpaperEnabled) { [weak self] in self?.applySetting() }
        applySetting()
        controller.reconcile()
    }

    private func applySetting() {
        if settings.liveWallpaperEnabled {
            source.start()
            KeybindCenter.shared.register(owner: Self.shortcutOwner, commands: ShortcutCommands.wallpaper) { [weak self] _ in
                self?.controller.toggleUserPaused()
            }
        } else {
            source.stop()
            KeybindCenter.shared.unregister(owner: Self.shortcutOwner)
        }
    }

    func shutdown() {
        token = nil
        source.stop()
        KeybindCenter.shared.unregister(owner: Self.shortcutOwner)
        controller.shutdown()
    }
}
