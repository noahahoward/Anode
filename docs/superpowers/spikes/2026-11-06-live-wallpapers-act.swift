import AppKit
import CoreGraphics
setbuf(stdout, nil)
let a = CommandLine.arguments
func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap) }
func move(_ x: Double, _ y: Double) { post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)) }
switch a[1] {
case "windows":
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
        let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
        print(String(format: "%@ [%@] %.0f,%.0f %.0fx%.0f", w[kCGWindowOwnerName as String] as? String ?? "?", w[kCGWindowName as String] as? String ?? "", b["X"] ?? 0, b["Y"] ?? 0, b["Width"] ?? 0, b["Height"] ?? 0))
    }
case "click":
    let x = Double(a[2])!, y = Double(a[3])!
    move(x, y); usleep(150_000)
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)); usleep(60_000)
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left))
case "space":   // space left|right  (synthetic control+arrow with fn+numpad flags, per the Anode notes)
    let key: CGKeyCode = a[2] == "left" ? 123 : 124
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
        e?.flags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
        e?.post(tap: .cgSessionEventTap)
        usleep(60_000)
    }
case "key":     // key <code> [cmd|ctrl|opt|shift ...]
    var f: CGEventFlags = []
    for m in a.dropFirst(3) { switch m { case "cmd": f.insert(.maskCommand); case "ctrl": f.insert(.maskControl); case "opt": f.insert(.maskAlternate); case "shift": f.insert(.maskShift); default: break } }
    for down in [true, false] { let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(a[2])!, keyDown: down); e?.flags = f; post(e) }
case "menubars":
    let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
    let n = list.filter { ($0[kCGWindowLayer as String] as? Int) == 24 && ($0[kCGWindowName as String] as? String) == "Menubar" && (($0[kCGWindowIsOnscreen as String] as? Int) ?? 0) == 1 }.count
    print("onscreen Menubar windows: \(n)")
default: break
}
