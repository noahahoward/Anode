#!/usr/bin/swift
// Diagnostic for "a menu bar widget draws as empty space".
//
//   swift widget-diagnose.swift
//
// It reproduces the exact geometry of WidgetRenderer.textImage and reports
// whether the resulting image contains any ink, so a blank widget can be told
// apart from a missing value. Reads nothing, writes nothing, changes nothing.
import AppKit
import Foundation

_ = NSApplication.shared          // NSStatusBar wants an app context

func rule(_ s: String) { print("\n\(s)\n" + String(repeating: "─", count: 66)) }

rule("MACHINE")
var sz = 0; sysctlbyname("hw.model", nil, &sz, nil, 0)
var buf = [CChar](repeating: 0, count: sz)
sysctlbyname("hw.model", &buf, &sz, nil, 0)
print("  hw.model              \(String(cString: buf))")
print("  macOS                 \(ProcessInfo.processInfo.operatingSystemVersionString)")

rule("THE PRIME SUSPECT — image height comes from here")
let thickness = NSStatusBar.system.thickness
print("  NSStatusBar.thickness \(thickness)   \(thickness > 0 ? "OK" : "<<< ZERO: every text widget is a zero-height image")")
print("  screens               \(NSScreen.screens.count), main backingScale \(NSScreen.main?.backingScaleFactor ?? -1)")

rule("SWAP, THE VALUE ITSELF")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
task.arguments = ["vm.swapusage"]
let pipe = Pipe(); task.standardOutput = pipe
try? task.run(); task.waitUntilExit()
let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
print("  " + out.trimmingCharacters(in: .whitespacesAndNewlines))

// Exactly WidgetRenderer.textImage, copied so this runs without the app.
func textImage(label: String?, value: String) -> NSImage {
    let h = NSStatusBar.system.thickness
    let valueFont = NSFont.monospacedDigitSystemFont(ofSize: label == nil ? 12 : 10.5, weight: .semibold)
    let labelFont = NSFont.systemFont(ofSize: 8, weight: .medium)
    let vAttrs: [NSAttributedString.Key: Any] = [.font: valueFont, .foregroundColor: NSColor.black]
    let lAttrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: NSColor.black]
    let vStr = NSAttributedString(string: value, attributes: vAttrs)
    let lStr = label.map { NSAttributedString(string: $0, attributes: lAttrs) }
    let vSize = vStr.size(); let lSize = lStr?.size() ?? .zero
    let pad: CGFloat = 3
    let w = max(vSize.width, lSize.width) + pad * 2
    let img = NSImage(size: NSSize(width: ceil(w), height: h), flipped: false) { _ in
        if let lStr {
            let vy = (h - vSize.height) / 2 - lSize.height / 2 + 1
            let ly = vy + vSize.height - 1
            lStr.draw(at: NSPoint(x: (w - lSize.width) / 2, y: ly))
            vStr.draw(at: NSPoint(x: (w - vSize.width) / 2, y: vy))
        } else {
            vStr.draw(at: NSPoint(x: pad, y: (h - vSize.height) / 2))
        }
        return true
    }
    img.isTemplate = true
    return img
}

/// Percentage of pixels with any alpha. 0 % is a blank widget, whatever the size says.
func inkCoverage(_ img: NSImage) -> (px: Int, inked: Int) {
    guard img.size.width >= 1, img.size.height >= 1,
          let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
              pixelsWide: Int(img.size.width), pixelsHigh: Int(img.size.height),
              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return (0, 0) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    var inked = 0
    for x in 0..<rep.pixelsWide { for y in 0..<rep.pixelsHigh {
        if let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.01 { inked += 1 }
    } }
    return (rep.pixelsWide * rep.pixelsHigh, inked)
}

rule("WHAT THE WIDGET WOULD ACTUALLY DRAW")
var worstInk = 100
var anyZeroHeight = false
for (lbl, val) in [("Swap", "0 B"), ("Swap", "256 KB"), ("Swap", "\u{2014}")] {
    let img = textImage(label: lbl, value: val)
    let (px, inked) = inkCoverage(img)
    let pct = px == 0 ? 0 : inked * 100 / px
    let verdict = img.size.height == 0 ? "BLANK — zero-height image"
                : inked == 0 ? "BLANK — sized but no ink"
                : "draws \(pct)% ink"
    // Plain interpolation, not String(format:) — %s mangles any non-ASCII value
    // (the em dash came out as mojibake, which in a diagnostic reads as a bug).
    let cell = { (t: String, n: Int) in t.padding(toLength: max(n, t.count), withPad: " ", startingAt: 0) }
    print("  \(cell(lbl, 6)) \(cell(val, 8))  \(Int(img.size.width)) x \(Int(img.size.height)) pt   \(verdict)")
    worstInk = min(worstInk, pct)
    if img.size.height == 0 { anyZeroHeight = true }
}

rule("PERSISTED WIDGET CONFIG  (dev.anode.app)")
if let d = UserDefaults(suiteName: "dev.anode.app"),
   let data = d.data(forKey: "com.anode.menubar.widgets.v1"),
   let s = String(data: data, encoding: .utf8) {
    print("  " + s)
    if s.components(separatedBy: "storage.swap.used").count - 1 > 1 {
        print("  <<< storage.swap.used appears MORE THAN ONCE — duplicate config")
    }
} else {
    print("  no stored config (defaults are in use)")
}
print("")

// ── One line for the person running this, who did not write it ──────────────
rule("VERDICT")
if anyZeroHeight || thickness == 0 {
    print("  THE RENDERER IS THE BUG. NSStatusBar.thickness is \(thickness), so every")
    print("  text widget is built as a zero-height image: full width, no content.")
    print("  Send this whole output back — it is the answer.")
} else if worstInk == 0 {
    print("  THE RENDERER IS THE BUG. The image is the right size but nothing is")
    print("  drawn into it, so the text is landing outside the canvas on your")
    print("  screen metrics. Send this whole output back — it is the answer.")
} else {
    print("  The renderer is FINE on this machine: a Swap widget would draw")
    print("  \(worstInk)% ink at \(Int(thickness))pt tall, including when swap reads 0 B.")
    print("  So the blank slot is not the drawing code, and the next suspect is the")
    print("  stored config printed above. Try: remove the Swap widget in Settings,")
    print("  quit Anode completely, reopen it, add Swap again. Then send this output.")
}
print("")
