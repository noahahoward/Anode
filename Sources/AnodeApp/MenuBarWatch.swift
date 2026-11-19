import AppKit

// ── The menu bar going away under an open menu ──────────────────────────────
//
// With "Automatically hide and show the menu bar" on, macOS's own Sound and Battery panels close when the bar slides away (the pointer
// leaves it). Anode's menus hang from the same icons and stayed on the screen: a tester's menu was still there after the bar was gone and
// a click elsewhere. While a menu is open it looks, every quarter of a second, whether the bar is on the screen, and closes the menu when
// it was and is not.
//
// The bar is a window of the window server at layer 24 ("Menubar", the full width of the screen and about 24 to 40 points tall). Hidden, it
// is above the top edge (or not listed). It only counts as gone after it was seen: a Mac on which the window cannot be found at all (a
// layout this was not measured on) never has a menu closed by this.

enum MenuBarVisibility {

    /// The layer of the menu bar's window (`kCGMainMenuWindowLevel`).
    static let layer = 24

    /// Whether a window list (as `CGWindowListCopyWindowInfo` gives it) has the menu bar on the screen: a window of the window server at
    /// the menu bar's layer, wide and thin, with more than half of it below the top edge.
    static func isShown(in windows: [[String: Any]]) -> Bool {
        windows.contains { w in
            guard (w[kCGWindowOwnerName as String] as? String) == "Window Server", (w[kCGWindowLayer as String] as? Int) == layer,
                  let b = w[kCGWindowBounds as String] as? [String: Double],
                  let width = b["Width"], let height = b["Height"], let y = b["Y"] else { return false }
            return height >= 15 && height <= 80 && width >= 400 && y + height > height / 2
        }
    }

    static func liveWindows() -> [[String: Any]] {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    }

    /// One look: the bar has gone when it is not there now and was seen there before.
    static func step(seenShown: Bool, shownNow: Bool) -> (seenShown: Bool, gone: Bool) {
        shownNow ? (true, false) : (seenShown, seenShown)
    }
}

final class MenuBarWatch {

    static let interval: TimeInterval = 0.25

    private var timer: Timer?
    private var seenShown = false

    /// Starts looking; `onGone` is called once, on the main queue, when the bar goes. Looking again with `start` begins afresh.
    func start(windows: @escaping () -> [[String: Any]] = MenuBarVisibility.liveWindows, onGone: @escaping () -> Void) {
        stop()
        seenShown = false
        func look() -> Bool {
            let r = MenuBarVisibility.step(seenShown: seenShown, shownNow: MenuBarVisibility.isShown(in: windows()))
            seenShown = r.seenShown
            return r.gone
        }
        if look() { onGone(); return }
        let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] timer in
            guard look() else { return }
            timer.invalidate()
            self?.timer = nil
            onGone()
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit { stop() }
}
