// THROWAWAY SPIKE: hz <seconds> [app|session]  — hold the built-in display at its lowest refresh rate (same resolution), then put it back.
import Foundation
import CoreGraphics
let d = CGMainDisplayID()
guard let cur = CGDisplayCopyDisplayMode(d) else { print("no mode"); exit(2) }
let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
let modes = (CGDisplayCopyAllDisplayModes(d, opts) as? [CGDisplayMode]) ?? []
let same = modes.filter { $0.width == cur.width && $0.height == cur.height && $0.pixelWidth == cur.pixelWidth && $0.pixelHeight == cur.pixelHeight && $0.isUsableForDesktopGUI() && $0.refreshRate > 0 }
guard let low = same.min(by: { $0.refreshRate < $1.refreshRate }), low.refreshRate < cur.refreshRate else { print("no lower rate than", cur.refreshRate); exit(3) }
let secs = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 10 : 10
let scope: CGConfigureOption = (CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "session") ? .forSession : .forAppOnly
func apply(_ m: CGDisplayMode) -> CGError {
    var c: CGDisplayConfigRef?
    CGBeginDisplayConfiguration(&c)
    CGConfigureDisplayWithDisplayMode(c, d, m, nil)
    return CGCompleteDisplayConfiguration(c, scope)
}
func restore() { _ = apply(cur) }
var sources: [DispatchSourceSignal] = []
for s in [SIGINT, SIGTERM, SIGHUP] {
    signal(s, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: s, queue: .main)
    src.setEventHandler { restore(); exit(0) }
    src.resume(); sources.append(src)
}
print("from", cur.refreshRate, "to", low.refreshRate, "->", apply(low).rawValue, "now", CGDisplayCopyDisplayMode(d)?.refreshRate ?? -1); fflush(stdout)
DispatchQueue.main.asyncAfter(deadline: .now() + secs) {
    restore()
    print("restored ->", CGDisplayCopyDisplayMode(d)?.refreshRate ?? -1)
    exit(0)
}
dispatchMain()
