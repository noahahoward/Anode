import AppKit

/// The menus of Anode's own that are open (the menu bar readings' list, Keep Awake's, Ultra Low Power's, the chevron's…): macOS menus, in
/// a tracking session of their own.
///
/// A click on another icon of the menu bar closes the open menu in the very frame the other icon's panel opens (`ClickAway`). Anode's
/// Sound and Battery menus open on a click that Anode took before any app saw it, so an open menu of Anode's never heard it, and stayed up
/// under the new panel until Anode's reading of macOS's own panel pressed that icon, a few hundred milliseconds later (measured: the
/// readings list went at 513 ms, the Sound menu was up at 221 ms): the new panel covered the left of it and the right showed beside the
/// panel, "half a menu", for as long as that took. Opening one of those menus now closes these first.
final class OpenMenus {

    static let shared = OpenMenus()

    /// A menu is held weakly: one that has gone is not one to close.
    private struct Entry { weak var menu: NSMenu? }
    private var entries: [Entry] = []
    private var observers: [NSObjectProtocol] = []
    private let cancel: (NSMenu) -> Void
    private let center: NotificationCenter

    /// `cancel` is what closes a menu (a test records it); `center` is where the menus announce that they begin and end tracking.
    init(center: NotificationCenter = .default, cancel: @escaping (NSMenu) -> Void = { $0.cancelTrackingWithoutAnimation() }) {
        self.center = center
        self.cancel = cancel
    }

    deinit { for o in observers { center.removeObserver(o) } }

    /// Starts listening (on the thread that posts: menus announce themselves on the main one). It has to be on before a menu opens: the
    /// announcement of one that was already open is not heard.
    func start() {
        guard observers.isEmpty else { return }
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { [weak self] note in
            guard let self, let menu = note.object as? NSMenu else { return }
            self.entries.removeAll { $0.menu == nil || $0.menu === menu }
            self.entries.append(Entry(menu: menu))
        })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil) { [weak self] note in
            guard let self, let menu = note.object as? NSMenu else { return }
            self.entries.removeAll { $0.menu == nil || $0.menu === menu }
        })
    }

    /// The menus open now, outermost first.
    var open: [NSMenu] { entries.compactMap(\.menu) }

    /// Closes every one of them at once, without the fade a menu takes when it is closed in its own time.
    func closeAll() {
        let menus = open
        entries.removeAll()
        for menu in menus { cancel(menu) }
    }
}
