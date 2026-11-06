import AppKit
import ApplicationServices

// Spike probe for the menu bar hider: does a huge-length status item push the items on its left off the bar?
// Stages: baseline (len 24) -> collapsed (len 10000) -> restored (len 24). Dumps every layer-25 window at each stage.
setbuf(stdout, nil)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let item = NSStatusBar.system.statusItem(withLength: 24)
item.autosaveName = "probe.divider"
item.button?.title = "◆"
let left = NSStatusBar.system.statusItem(withLength: 24)
left.autosaveName = "probe.left"
left.button?.title = "B"

func dump(_ stage: String) {
    let me = ProcessInfo.processInfo.processIdentifier
    let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
    print("== \(stage)")
    let rows = list.filter { w in
        let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
        return (b["Y"] ?? 99) <= 2 && (b["Height"] ?? 99) <= 40 && (b["Width"] ?? 0) < 1700
    }
    for w in rows {
        let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        let pid = w[kCGWindowOwnerPID as String] as? Int ?? 0
        let on = (w[kCGWindowIsOnscreen as String] as? Int) ?? 0
        let name = w[kCGWindowName as String] as? String ?? ""
        print("layer=\(w[kCGWindowLayer as String] ?? "?")", terminator: " "); print(String(format: "x=%8.1f y=%5.1f w=%7.1f h=%4.1f on=%d  %@%@ [%@]", b["X"] ?? 0, b["Y"] ?? 0, b["Width"] ?? 0, b["Height"] ?? 0, on,
                     pid == Int(me) ? "PROBE " : "", owner, name))
    }
}


func ax(_ el: AXUIElement, _ a: String) -> AnyObject? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(el, a as CFString, &v) == .success ? v : nil }
func axPoint(_ el: AXUIElement, _ a: String) -> CGPoint? { guard let v = ax(el, a) else { return nil }; var p = CGPoint.zero; AXValueGetValue(v as! AXValue, .cgPoint, &p); return p }
func axSize(_ el: AXUIElement, _ a: String) -> CGSize? { guard let v = ax(el, a) else { return nil }; var p = CGSize.zero; AXValueGetValue(v as! AXValue, .cgSize, &p); return p }
func dumpAX(_ stage: String) {
    print("== AX \(stage)  trusted=\(AXIsProcessTrusted())  dividerWin=\(String(describing: item.button?.window?.frame)) leftWin=\(String(describing: left.button?.window?.frame)) leftVisible=\(left.button?.window?.isVisible ?? false) occl=\(String(describing: left.button?.window?.occlusionState.rawValue))")
    for a in NSWorkspace.shared.runningApplications {
        let el = AXUIElementCreateApplication(a.processIdentifier)
        guard let bar = ax(el, "AXExtrasMenuBar") else { continue }
        let kids = (ax(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        for k in kids {
            let p = axPoint(k, kAXPositionAttribute), s = axSize(k, kAXSizeAttribute)
            print(String(format: "x=%8.1f w=%6.1f  %@ | %@", p?.x ?? -1, s?.width ?? -1, a.localizedName ?? "?", (ax(k, kAXDescriptionAttribute) as? String) ?? (ax(k, kAXTitleAttribute) as? String) ?? ""))
        }
    }
}
print("screens:")
for s in NSScreen.screens { print(" frame=\(s.frame) safeTop=\(s.safeAreaInsets.top)") }

DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { dump("baseline len=24"); dumpAX("baseline len=24") }
DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { item.length = 10000 }
DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { dump("collapsed len=10000"); dumpAX("collapsed len=10000") }
DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { item.length = 24 }
DispatchQueue.main.asyncAfter(deadline: .now() + 9.5) { dump("restored len=24"); dumpAX("restored len=24") }
DispatchQueue.main.asyncAfter(deadline: .now() + 10.5) { exit(0) }
app.run()
