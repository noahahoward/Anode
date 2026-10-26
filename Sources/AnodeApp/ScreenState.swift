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
}
