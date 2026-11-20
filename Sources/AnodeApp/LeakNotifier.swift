import Foundation
import UserNotifications
import PowerKit

// ── Memory Watch's notifications ────────────────────────────────────────────
//
// The ONLY file that imports UserNotifications. Everything else talks to `LeakNotifying`, which the tests replace with a
// fake: the test process has no app bundle, and asking the real notification center for anything there raises an exception.
//
// `UNUserNotificationCenter` is touched only inside `UNLeakNotifier`, only when one of its methods is called, and never when
// the object is made.

/// Whether macOS lets Anode show a banner.
enum LeakAuthorization: Equatable {
    case notDetermined
    case denied
    case authorized
}

extension Finding {
    /// What one diagnostic window and one notification are keyed by: the app's identity key for an app (every helper of an
    /// app is one thing), `pid:start` for a tool or daemon (every `node` on a Mac is not one thing).
    var windowKey: String {
        isApp ? identityKey : "\(processKey.pid):\(processKey.startAbsTime)"
    }
}

protocol LeakNotifying: AnyObject {
    /// What macOS says now. `completion` is always called on the main thread.
    func authorizationStatus(completion: @escaping (LeakAuthorization) -> Void)
    /// Ask macOS (shows its prompt the first time). `completion` gets the answer, on the main thread.
    func requestAuthorization(completion: @escaping (LeakAuthorization) -> Void)
    /// Show a banner for the finding, titled by `finding.notificationTitle`. No sound.
    func post(_ finding: Finding)
    /// Take the banner with this window key out of Notification Center.
    func removeDelivered(forKey key: String)
    /// Take every banner Anode has put there out of Notification Center.
    func removeAllDelivered()
    /// Become the notification center's delegate: banners show even while Anode is in front, and a click calls `onOpen` with
    /// the clicked banner's window key, on the main thread.
    func installDelegate(onOpen: @escaping (String) -> Void)
    func removeDelegate()
}

final class UNLeakNotifier: NSObject, LeakNotifying, UNUserNotificationCenterDelegate {

    static let userInfoKey = "memoryWatch.windowKey"

    private var onOpen: ((String) -> Void)?
    private var delegateInstalled = false

    /// Nil in the test copy of the app (`AppSandbox`: the person's own approvals are not to be touched) and in a process with
    /// no bundle (a test run), where the real center cannot be used.
    private var center: UNUserNotificationCenter? {
        guard !AppSandbox.isOn, Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    // ── Authorization ───────────────────────────────────────────────────────

    static func map(status: UNAuthorizationStatus, alert: UNNotificationSetting) -> LeakAuthorization {
        switch status {
        case .notDetermined:
            return .notDetermined
        case .authorized, .provisional:
            // Allowed in general but with banners switched off: nothing would show.
            return alert == .disabled ? .denied : .authorized
        case .denied:
            return .denied
        @unknown default:
            return .denied
        }
    }

    func authorizationStatus(completion: @escaping (LeakAuthorization) -> Void) {
        guard let center else {
            DispatchQueue.main.async { completion(.notDetermined) }
            return
        }
        center.getNotificationSettings { settings in
            let mapped = Self.map(status: settings.authorizationStatus, alert: settings.alertSetting)
            DispatchQueue.main.async { completion(mapped) }
        }
    }

    func requestAuthorization(completion: @escaping (LeakAuthorization) -> Void) {
        guard let center else {
            DispatchQueue.main.async { completion(.notDetermined) }
            return
        }
        center.requestAuthorization(options: [.alert]) { [weak self] _, _ in
            guard let self else {
                DispatchQueue.main.async { completion(.notDetermined) }
                return
            }
            // The answer is read back rather than taken from `granted`, so it is what Settings will show.
            self.authorizationStatus(completion: completion)
        }
    }

    // ── Posting ─────────────────────────────────────────────────────────────

    /// What a banner says, from the finding itself (a leak and a low-memory warning have their own title), and whether it is
    /// marked time-sensitive (a low-memory warning is: it is about to matter). Never a sound. A plain function, so it is
    /// tested without the notification center.
    static func payload(for finding: Finding) -> (title: String, body: String, timeSensitive: Bool) {
        (finding.notificationTitle, finding.notificationBody, finding.tier == .pressure)
    }

    func post(_ finding: Finding) {
        guard let center else { return }
        let key = finding.windowKey
        let payload = Self.payload(for: finding)
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        // Time-sensitive is a hint to macOS about urgency (an app without that entitlement is shown an ordinary banner); it
        // adds no sound.
        if payload.timeSensitive { content.interruptionLevel = .timeSensitive }
        content.threadIdentifier = key
        content.userInfo = [Self.userInfoKey: key]
        let request = UNNotificationRequest(identifier: key, content: content, trigger: nil)
        center.add(request) { _ in }
    }

    func removeDelivered(forKey key: String) {
        guard let center else { return }
        center.removeDeliveredNotifications(withIdentifiers: [key])
    }

    func removeAllDelivered() {
        guard let center else { return }
        center.removeAllDeliveredNotifications()
    }

    // ── Delegate ────────────────────────────────────────────────────────────

    func installDelegate(onOpen: @escaping (String) -> Void) {
        guard let center else { return }
        self.onOpen = onOpen
        delegateInstalled = true
        // The center holds its delegate weakly: this object is kept alive by whoever owns the notifier.
        center.delegate = self
    }

    func removeDelegate() {
        guard delegateInstalled, let center else { return }
        delegateInstalled = false
        onOpen = nil
        if center.delegate === self { center.delegate = nil }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // A banner even while Anode is the app in front.
        completionHandler([.banner])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let key = response.notification.request.content.userInfo[Self.userInfoKey] as? String
        DispatchQueue.main.async { [weak self] in
            if let key { self?.onOpen?(key) }
        }
        completionHandler()
    }
}
