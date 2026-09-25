// probe — observes Anode from outside, at the three places a freeze could live:
//   items <pid>        what the APP believes each widget says (AX help = tooltip)
//                      and where the SYSTEM placed it
//   windows <pid>      what WindowServer holds for the app
//   stat <png>         what actually reached the screen: mean/stddev of luma
//                      and mean alpha, so "transparent" and "blank" are numbers
import AppKit
import ApplicationServices
import CoreGraphics
import ImageIO

func ax(_ e: AXUIElement, _ a: String) -> AnyObject? {
    var v: AnyObject?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}
let args = CommandLine.arguments
switch args[1] {
case "items":
    let app = AXUIElementCreateApplication(pid_t(args[2])!)
    guard let bar = ax(app, "AXExtrasMenuBar") else { print("NO_EXTRAS_BAR"); exit(0) }
    let kids = ax(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] ?? []
    for k in kids {
        var p = CGPoint.zero, s = CGSize.zero
        if let pv = ax(k, kAXPositionAttribute) { AXValueGetValue(pv as! AXValue, .cgPoint, &p) }
        if let sv = ax(k, kAXSizeAttribute) { AXValueGetValue(sv as! AXValue, .cgSize, &s) }
        let help = (ax(k, kAXHelpAttribute) as? String ?? "").replacingOccurrences(of: "\n", with: " ")
        print("\(Int(p.x))\t\(Int(p.y))\t\(Int(s.width))\t\(Int(s.height))\t\(help)")
    }
case "windows":
    let pid = Int32(args[2])!
    let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
    for w in all where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
        let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        print("\(w[kCGWindowNumber as String]!)\t\((w[kCGWindowIsOnscreen as String] as? Bool) == true ? 1 : 0)\t\(w[kCGWindowAlpha as String] ?? "?")\t\(w[kCGWindowLayer as String]!)\t\(b["X"]!)\t\(b["Y"]!)\t\(b["Width"]!)\t\(b["Height"]!)\t\(w[kCGWindowName as String] ?? "")")
    }
case "stat":
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("NOIMG"); exit(0) }
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    var sum = 0.0, sq = 0.0, asum = 0.0; var hash: UInt64 = 1469598103934665603
    let n = Double(w * h)
    for i in stride(from: 0, to: px.count, by: 4) {
        let l = 0.299 * Double(px[i]) + 0.587 * Double(px[i+1]) + 0.114 * Double(px[i+2])
        sum += l; sq += l * l; asum += Double(px[i+3])
        hash = (hash ^ UInt64(px[i] >> 3)) &* 1099511628211   // coarse: ignore LSB noise
    }
    let mean = sum / n
    print(String(format: "%dx%d mean=%.1f sd=%.1f alpha=%.1f hash=%016llx", w, h, mean,
                 (sq / n - mean * mean).squareRoot(), asum / n, hash))
default: print("usage")
}
