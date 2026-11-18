import CoreGraphics

/// How macOS closes a menu bar panel when the click that closes it lands somewhere else (measured at 120 fps on macOS 27). On another
/// menu bar item (another icon's panel, the Apple menu) the old panel is gone in the very frame the new one appears, with no fade; on
/// empty menu bar, a window or the desktop it fades out in a straight line over about 240 ms.
public enum ClickAway {
    /// `role` is what Accessibility says is under the click (`AXMenuBarItem` for an icon or a menu of the bar, `AXMenuBar` for the bar
    /// between them), nil when it could not be asked or did not answer in time.
    public static func fades(whenClickLandsOn role: String?) -> Bool { role != "AXMenuBarItem" }

    /// Whether a press of the mouse closes Anode's menu, which hangs from macOS's icon. On the menu itself, never. Anywhere else,
    /// always, except on the icon: there a plain press of the left button is the icon's own toggle (the click gate takes it and
    /// opens or closes the menu), and the menu must not also close from this side. Every other press on the icon is one the gate
    /// does not take, so macOS gets it and opens its own context menu (a right click, a Control-click, a middle click) or does its
    /// own thing with it (Command, Option): the menu closes, as macOS's own panel does, and the two are never up together.
    /// `plainLeftPress` is a press of the left button with none of Command, Option or Control held (the gate's own rule).
    public static func closes(onIcon: Bool, onMenu: Bool, plainLeftPress: Bool) -> Bool {
        if onMenu { return false }
        if onIcon { return !plainLeftPress }
        return true
    }

    /// Whether a key press closes the menu as its Esc: the key is Esc, and it was pressed after the menu came up. An Esc sent a moment
    /// before it opened (to close a context menu of the icon, see `MenuBarContextMenu`) is delivered to a listener that is already
    /// there by then, and is not the person's wish to close what had not opened yet. Times are system uptime, as an event's are.
    public static func escapeCloses(keyCode: UInt16, eventTime: Double, openedAt: Double) -> Bool {
        keyCode == 53 && eventTime > openedAt
    }
}

/// A menu of macOS's own that the menu bar's icons open on a right click (or a Control-click): "Show Percentage", "Remove from Menu
/// Bar". It is a window of Control Center at the pop-up menu level, and unlike macOS's panel (a click on the icon) it is not among
/// the windows Accessibility lists for Control Center (measured on macOS 27.3: a 344 x 242 window at the menu level, its top above
/// the screen, gone when Esc is pressed; no Accessibility action on the icon closes it).
public enum MenuBarContextMenu {

    public struct Window: Equatable {
        public var ownerPID: Int32
        public var layer: Int
        public var bounds: CGRect
        public init(ownerPID: Int32, layer: Int, bounds: CGRect) { self.ownerPID = ownerPID; self.layer = layer; self.bounds = bounds }
    }

    /// The window level of a pop-up menu.
    public static let menuLevel = 101

    /// Whether one of these menus is on the screen: a window of `owner` (Control Center) at the menu level that is not macOS's own
    /// panel (`panelIsOpen`: Accessibility lists that one) and not parked off the screen (Anode moves macOS's panel there while
    /// it reads it).
    public static func isOpen(windows: [Window], owner: Int32, panelIsOpen: Bool) -> Bool {
        guard !panelIsOpen else { return false }
        return windows.contains { $0.ownerPID == owner && $0.layer == menuLevel && $0.bounds.minX > -1000 }
    }
}
