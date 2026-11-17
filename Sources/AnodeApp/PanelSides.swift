import AppKit
import PowerKit

/// Which side of its icon macOS opens a menu bar panel on (`MenuPanelPlacement`), as Anode has seen it: the driver notes where the
/// window macOS opened began (before it moves it away), and Anode's menus and the picture over macOS's first frames follow it. An
/// icon not seen yet gets the guess, and the first panel macOS opens for it makes Anode's menu move if the guess was wrong.
final class PanelSides {

    static let shared = PanelSides()

    /// Posted on the main queue when macOS opened a panel on another side than was assumed for its icon.
    static let changed = Notification.Name("dev.anode.panelSideChanged")

    private let lock = NSLock()
    private var memory = PanelSideMemory()
    private let leftLimit: () -> CGFloat

    /// The left end of the room a panel's window can have on the menu bar's screen: the right edge of the notch, else the screen's.
    static func screenLeftLimit() -> CGFloat {
        guard let screen = NSScreen.screens.first else { return 0 }
        return screen.auxiliaryTopRightArea?.minX ?? screen.frame.minX
    }

    init(leftLimit: @escaping () -> CGFloat = PanelSides.screenLeftLimit) { self.leftLimit = leftLimit }

    func side(for icon: CGRect) -> PanelSide {
        lock.lock(); defer { lock.unlock() }
        return memory.side(for: icon, leftLimit: leftLimit())
    }

    /// The sides macOS's panel might open on for the icon: the one it is known to, else both.
    func sidesToCover(for icon: CGRect) -> [PanelSide] {
        lock.lock(); defer { lock.unlock() }
        return memory.knows(icon) ? [memory.side(for: icon, leftLimit: leftLimit())] : [.endsAtIcon, .startsAtIcon]
    }

    /// macOS opened a panel for `icon` in a window that began at `windowMinX`.
    func learn(windowMinX: CGFloat, icon: CGRect) {
        let seen = MenuPanelPlacement.side(ofWindowMinX: windowMinX, icon: icon)
        lock.lock()
        let changed = memory.learn(seen, for: icon, leftLimit: leftLimit())
        lock.unlock()
        if changed { DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: nil) } }
    }

    /// Where a menu `width` wide starts for the icon at `anchor`, kept inside the screen.
    static func menuMinX(anchor: CGRect, width: CGFloat, in screen: NSScreen) -> CGFloat {
        let x = MenuPanelPlacement.minX(icon: anchor, side: shared.side(for: anchor), width: width)
        return min(max(8, x), screen.frame.width - width - 8)
    }
}
