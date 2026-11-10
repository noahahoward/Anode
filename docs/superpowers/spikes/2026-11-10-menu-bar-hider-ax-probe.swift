// THROWAWAY SPIKE (read-only): every menu bar item via the Accessibility "extras menu bar". Nothing is pressed.
import AppKit
import ApplicationServices
print("AX trusted:", AXIsProcessTrusted())
let screen = NSScreen.screens[0]
let nl = screen.auxiliaryTopLeftArea?.maxX ?? 0, nr = screen.auxiliaryTopRightArea?.minX ?? 0
print("notch x \(nl)..\(nr)")
func attr(_ e: AXUIElement, _ k: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil }
var rows: [(Double, String)] = []
for app in NSWorkspace.shared.runningApplications {
    let el = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(el, 0.4)
    guard let bar = attr(el, "AXExtrasMenuBar") else { continue }
    let kids = (attr(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    for k in kids {
        var p = CGPoint.zero, s = CGSize.zero
        if let pv = attr(k, kAXPositionAttribute) { AXValueGetValue(pv as! AXValue, .cgPoint, &p) }
        if let sv = attr(k, kAXSizeAttribute) { AXValueGetValue(sv as! AXValue, .cgSize, &s) }
        var acts: CFArray?; AXUIElementCopyActionNames(k, &acts)
        let title = (attr(k, kAXTitleAttribute) as? String) ?? (attr(k, kAXDescriptionAttribute) as? String) ?? (attr(k, kAXIdentifierAttribute) as? String) ?? ""
        let zone = p.x + s.width <= nl ? "left" : (p.x >= nr ? "right" : "UNDER-notch")
        rows.append((p.x, String(format: "x %6.0f w %4.0f y %3.0f %-11@ %-22@ title:%-28@ actions:%@", p.x, s.width, p.y, zone as NSString, (app.localizedName ?? "?") as NSString, String(title.prefix(26)) as NSString, ((acts as? [String]) ?? []).joined(separator: ",") as NSString)))
    }
}
rows.sorted { $0.0 < $1.0 }.forEach { print($0.1) }
print("items:", rows.count)
