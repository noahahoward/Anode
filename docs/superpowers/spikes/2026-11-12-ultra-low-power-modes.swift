import CoreGraphics
import Foundation
let d = CGMainDisplayID()
let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
let modes = (CGDisplayCopyAllDisplayModes(d, opts) as? [CGDisplayMode]) ?? []
let cur = CGDisplayCopyDisplayMode(d)
print("builtin:", CGDisplayIsBuiltin(d) != 0, "current:", cur?.width ?? 0, "x", cur?.height ?? 0, "@", cur?.refreshRate ?? 0, "modes:", modes.count)
var rates: [Double: Int] = [:]
for m in modes { rates[m.refreshRate, default: 0] += 1 }
print("all rates:", rates.keys.sorted().map { String(format: "%.2f", $0) })
let same = modes.filter { $0.width == cur?.width && $0.height == cur?.height && $0.pixelWidth == cur?.pixelWidth }
print("rates at current resolution:", Set(same.map { $0.refreshRate }).sorted().map { String(format: "%.2f", $0) })
