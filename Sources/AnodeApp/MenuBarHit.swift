import ApplicationServices
import CoreGraphics

/// What is under a click in the menu bar, as Accessibility says (see `ClickAway`).
enum MenuBarHit {

    private static let systemWide: AXUIElement = {
        let e = AXUIElementCreateSystemWide()
        // A click that has already happened is not worth waiting for: no answer in time is "nothing to say".
        AXUIElementSetMessagingTimeout(e, 0.05)
        return e
    }()

    /// The role of the element under `point` (top-left global points): `AXMenuBarItem` on an icon or a menu of the bar, `AXMenuBar`
    /// on the bar between them. Nil when Accessibility is not allowed or does not answer.
    static func role(at point: CGPoint) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        var hit: AXUIElement?
        // On the screen's very top row Accessibility answers with the whole bar, not the item: the row below is the same item.
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(max(point.y, 1)), &hit) == .success, let hit else { return nil }
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(hit, kAXRoleAttribute as CFString, &role) == .success else { return nil }
        return role as? String
    }
}
