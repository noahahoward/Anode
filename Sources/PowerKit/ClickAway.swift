/// How macOS closes a menu bar panel when the click that closes it lands somewhere else (measured at 120 fps on macOS 27). On another
/// menu bar item (another icon's panel, the Apple menu) the old panel is gone in the very frame the new one appears, with no fade; on
/// empty menu bar, a window or the desktop it fades out in a straight line over about 240 ms.
public enum ClickAway {
    /// `role` is what Accessibility says is under the click (`AXMenuBarItem` for an icon or a menu of the bar, `AXMenuBar` for the bar
    /// between them), nil when it could not be asked or did not answer in time.
    public static func fades(whenClickLandsOn role: String?) -> Bool { role != "AXMenuBarItem" }
}
