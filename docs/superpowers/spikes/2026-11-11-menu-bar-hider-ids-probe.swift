// THROWAWAY SPIKE (read-only): every menu bar item with identifier, title, description, frame and actions. Nothing is pressed.
import AppKit
import ApplicationServices
print("AX trusted:", AXIsProcessTrusted())
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
        let id = (attr(k, kAXIdentifierAttribute) as? String) ?? "-"
        let title = (attr(k, kAXTitleAttribute) as? String) ?? "-"
        let desc = (attr(k, kAXDescriptionAttribute) as? String) ?? "-"
        rows.append((p.x, "x \(Int(p.x)) y \(Int(p.y)) \(Int(s.width))x\(Int(s.height)) | \(app.bundleIdentifier ?? "?") (\(app.localizedName ?? "?")) | id=\(id) | title=\(title) | desc=\(desc) | \(((acts as? [String]) ?? []).joined(separator: ","))"))
    }
}
rows.sorted { $0.0 < $1.0 }.forEach { print($0.1) }
print("items:", rows.count)
