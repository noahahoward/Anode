// THROWAWAY SPIKE: AXPress one menu bar item (by bundle id and, for the system's items, identifier), print where its menu
// opened (the AXMenu's frame), then dismiss it with AXCancel on the menu. No cursor, no clicks, no keys.
// usage: press_probe <bundleID> <identifier or -> <screenshot.png>
import AppKit
import ApplicationServices
func attr(_ e: AXUIElement, _ k: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil }
func frame(_ e: AXUIElement) -> CGRect {
    var p = CGPoint.zero, s = CGSize.zero
    if let pv = attr(e, kAXPositionAttribute) { AXValueGetValue(pv as! AXValue, .cgPoint, &p) }
    if let sv = attr(e, kAXSizeAttribute) { AXValueGetValue(sv as! AXValue, .cgSize, &s) }
    return CGRect(origin: p, size: s)
}
func hasAction(_ e: AXUIElement, _ a: String) -> Bool { var acts: CFArray?; AXUIElementCopyActionNames(e, &acts); return ((acts as? [String]) ?? []).contains(a) }
let args = CommandLine.arguments
let bundle = args[1], wantID = args.count > 2 && args[2] != "-" ? args[2] : nil, shot = args.count > 3 ? args[3] : "/tmp/press.png"
guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundle }) else { print("not running"); exit(1) }
let root = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetMessagingTimeout(root, 1.0)
guard let bar = attr(root, "AXExtrasMenuBar"), let kids = attr(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] else { print("no extras bar"); exit(1) }
var target: AXUIElement?, targetFrame = CGRect.zero
for k in kids {
    let inner = (attr(k, kAXChildrenAttribute) as? [AXUIElement])?.first
    let id = (attr(k, kAXIdentifierAttribute) as? String) ?? inner.flatMap { attr($0, kAXIdentifierAttribute) as? String }
    let desc = (attr(k, kAXDescriptionAttribute) as? String)
    if wantID == nil || id == wantID || desc == wantID {
        target = hasAction(k, kAXPressAction as String) ? k : (inner.map { hasAction($0, kAXPressAction as String) ? $0 : k } ?? k)
        targetFrame = frame(k)
        break
    }
}
guard let target else { print("item not found"); exit(1) }
print("item frame:", targetFrame)
let before = Date()
let rc = AXUIElementPerformAction(target, kAXPressAction as CFString)
print("AXPress ->", rc.rawValue, "(0 = success)")
Thread.sleep(forTimeInterval: 1.0)
// The menu: a child of the item (or of the item's inner element) with role AXMenu.
func findMenu(_ e: AXUIElement, depth: Int) -> AXUIElement? {
    if (attr(e, kAXRoleAttribute) as? String) == "AXMenu" { return e }
    guard depth > 0, let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
    for k in kids { if let m = findMenu(k, depth: depth - 1) { return m } }
    return nil
}
let capture = Process()
capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
capture.arguments = ["-x", "-R0,0,1800,1169", shot]
try? capture.run(); capture.waitUntilExit()
if let m = findMenu(target, depth: 3) {
    print("menu frame:", frame(m))
    print("screen frame:", NSScreen.screens.first?.frame ?? .zero)
    print("AXCancel ->", AXUIElementPerformAction(m, "AXCancel" as CFString).rawValue)
} else {
    print("no AXMenu child found")
    print("AXCancel on item ->", AXUIElementPerformAction(target, "AXCancel" as CFString).rawValue)
}
print("elapsed", Date().timeIntervalSince(before))
