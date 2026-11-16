import AppKit
import PowerKit

/// Per-app volume is on while the Sound menu is on and its own switch is: then the menu has an Apps section and an app that was
/// changed has a tap. At any other time (a switch turned off, Anode quitting) every app is itself again.
final class AppAudioCoordinator {
    private let settings: Settings
    private let makeRouter: () -> AppAudioRouter
    private let attach: (AppAudioRouter?) -> Void
    private var router: AppAudioRouter?
    private var observers: [AnyObject] = []
    private var stopped = false

    init(settings: Settings, makeRouter: @escaping () -> AppAudioRouter, attach: @escaping (AppAudioRouter?) -> Void) {
        self.settings = settings; self.makeRouter = makeRouter; self.attach = attach
    }

    func start() {
        guard observers.isEmpty else { return }
        observers = [settings.observe(Settings.Key.soundMenuEnabled) { [weak self] in self?.apply() },
                     settings.observe(Settings.Key.appAudioEnabled) { [weak self] in self?.apply() }] as [AnyObject]
        apply()
    }

    func stop() {
        stopped = true
        observers = []
        end()
    }

    private func apply() {
        guard !stopped else { return }
        if settings.soundMenuEnabled && settings.appAudioEnabled {
            guard router == nil else { return }
            let r = makeRouter()
            router = r
            attach(r)
            r.reconcile()
        } else {
            end()
        }
    }

    private func end() {
        guard let r = router else { return }
        router = nil
        attach(nil)
        r.shutdown()
    }

    /// The router the menu is using now, if any.
    var current: AppAudioRouter? { router }

    /// The real thing: Core Audio taps, listing the apps the person has open.
    static func live(settings: Settings = .shared, attach: @escaping (AppAudioRouter?) -> Void) -> AppAudioCoordinator {
        AppAudioCoordinator(settings: settings, makeRouter: {
            let running = { () -> Set<String> in
                Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.bundleIdentifier))
            }
            return AppAudioRouter(settings: settings, store: AppAudioStore(), backend: CoreAudioAppBackend(),
                                  bundleID: { Bundle(path: $0)?.bundleIdentifier },
                                  name: { path in
                                      let b = Bundle(path: path)
                                      return (b?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                                          ?? (b?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                                          ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                                  },
                                  // Anode itself is not an app whose volume the person sets here.
                                  isListable: { $0 != Bundle.main.bundleIdentifier && running().contains($0) },
                                  displayName: { id in NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == id }?.localizedName })
        }, attach: attach)
    }
}
