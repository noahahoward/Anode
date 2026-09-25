// dmode list | dmode set <index> | dmode current — main display mode, session-scoped
// (CGConfigureOption.forSession reverts at logout, so nothing here is permanent).
import CoreGraphics
import Foundation
let d = CGMainDisplayID()
let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
let modes = (CGDisplayCopyAllDisplayModes(d, opts) as? [CGDisplayMode] ?? []).filter { $0.isUsableForDesktopGUI() }
func desc(_ m: CGDisplayMode) -> String { "\(m.width)x\(m.height) px=\(m.pixelWidth)x\(m.pixelHeight) hz=\(m.refreshRate)" }
switch CommandLine.arguments[1] {
case "list": for (i, m) in modes.enumerated() { print(i, desc(m)) }
case "current": print(desc(CGDisplayCopyDisplayMode(d)!))
case "set":
    let m = modes[Int(CommandLine.arguments[2])!]
    var cfg: CGDisplayConfigRef?
    CGBeginDisplayConfiguration(&cfg)
    CGConfigureDisplayWithDisplayMode(cfg, d, m, nil)
    print(CGCompleteDisplayConfiguration(cfg, .forSession).rawValue, desc(m))
default: break
}
