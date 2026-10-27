import AppKit

/// What the screens are showing, as far as the window list can say. Shared by everything that
/// must stand down while a full-screen window is up: its menu bar is hidden, so a backdrop
/// drawn there is a black band over the content and a status item looks "parked".
///
/// Judged from the window list, not `NSScreen.visibleFrame`: an external display keeps
/// reporting its normal visible area while a window is full screen on it.
enum ScreenState {

    /// Is some ordinary on-screen window covering all of `screen`?
    static func showsFullScreenWindow(_ screen: NSScreen, primaryHeight: CGFloat,
                                      windowInfo: [[String: Any]]) -> Bool {
        let frame = CGRect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY,
                           width: screen.frame.width, height: screen.frame.height)
        return windowInfo.contains { entry in
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let dict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict) else { return false }
            return MenuBarBackdropGeometry.coversWholeScreen(bounds, screen: frame)
        }
    }

    /// Is any screen showing a full-screen window right now? One window query.
    static func anyScreenShowsFullScreenWindow() -> Bool {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                              kCGNullWindowID) as? [[String: Any]] ?? []
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSScreen.screens.contains { showsFullScreenWindow($0, primaryHeight: primaryHeight, windowInfo: info) }
    }

    /// A screen's frame in the window server's coordinates (origin top-left, y down).
    static func cgFrame(of screen: NSScreen, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY,
               width: screen.frame.width, height: screen.frame.height)
    }

    /// Is `bounds` an ordinary window on `screen`: big enough to be what the display is showing,
    /// not a small floating widget? A window counts when it covers at least `minAreaFraction` of
    /// the screen — a music player's 270 x 515 pt panel on a 1800 x 1169 display is 6.6% and does
    /// not; a half-width editor is 50% and does. Pure, for tests.
    static func isOrdinaryWindow(_ bounds: CGRect, on screen: CGRect, minAreaFraction: CGFloat = 0.12) -> Bool {
        let overlap = bounds.intersection(screen)
        guard !overlap.isNull, screen.width > 0, screen.height > 0 else { return false }
        return overlap.width * overlap.height >= screen.width * screen.height * minAreaFraction
    }

    /// Is some ordinary window showing on `screen`? When none is, what the display shows is the
    /// desktop. Layer 0 windows only: the menu bar, the Dock, widgets and Anode's own strips live
    /// at other layers and never count.
    static func hasOrdinaryWindow(on screen: CGRect, windowInfo: [[String: Any]]) -> Bool {
        windowInfo.contains { entry in
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let dict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict) else { return false }
            return isOrdinaryWindow(bounds, on: screen)
        }
    }
}
