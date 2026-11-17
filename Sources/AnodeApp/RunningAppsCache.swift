import AppKit
import PowerKit

/// The regular apps that are open, as of a moment ago. Asking macOS for them costs a round trip to LaunchServices for each app,
/// and the Sound menu is rebuilt on every step of a volume drag: so the list is kept, and read again after `maxAge` seconds or when
/// an app launches or quits.
final class RunningAppsCache {
    struct App: Equatable {
        let id: String            // the bundle id, or LooseApp's path id for a bare executable
        let name: String
        let executablePath: String?   // set for a bare executable only
    }

    private let maxAge: TimeInterval
    private let now: () -> Date
    private let fetch: () -> [App]
    private var snapshot: (at: Date, apps: [App])?
    private var observers: [NSObjectProtocol] = []

    init(maxAge: TimeInterval = 2, now: @escaping () -> Date = Date.init, fetch: @escaping () -> [App]) {
        self.maxAge = maxAge; self.now = now; self.fetch = fetch
    }

    deinit { for o in observers { NSWorkspace.shared.notificationCenter.removeObserver(o) } }

    var apps: [App] {
        if let s = snapshot, now().timeIntervalSince(s.at) < maxAge { return s.apps }
        let apps = fetch()
        snapshot = (now(), apps)
        return apps
    }

    func invalidate() { snapshot = nil }

    /// Reads again as soon as an app launches or quits.
    func watchWorkspace() {
        guard observers.isEmpty else { return }
        observers = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map {
            NSWorkspace.shared.notificationCenter.addObserver(forName: $0, object: nil, queue: .main) { [weak self] _ in self?.invalidate() }
        }
    }

    /// The real list: every regular app, a bare executable named by its path.
    static func live() -> RunningAppsCache {
        let cache = RunningAppsCache {
            NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap { app in
                guard let name = app.localizedName else { return nil }
                if let id = app.bundleIdentifier { return App(id: id, name: name, executablePath: nil) }
                return app.executableURL.map { App(id: LooseApp.id(forExecutable: $0.path), name: name, executablePath: $0.path) }
            }
        }
        cache.watchWorkspace()
        return cache
    }
}
