// THROWAWAY SPIKE (read-only): is the menu bar a flat colour? Captures the bar band with ScreenCaptureKit a few times, 20 s apart,
// and prints the lowest and highest luminance and the largest channel value seen between x 1060 and 1500 (where the cover goes).
import AppKit
import ScreenCaptureKit
import Foundation

@available(macOS 14.0, *)
func sample() async throws -> String {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = content.displays.first else { return "no display" }
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let cfg = SCStreamConfiguration()
    cfg.sourceRect = CGRect(x: 1060, y: 0, width: 440, height: 8)    // the top 8 pt: no icons are drawn there
    cfg.width = 880; cfg.height = 16
    cfg.pixelFormat = kCVPixelFormatType_32BGRA
    cfg.showsCursor = false
    let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    let w = img.width, h = img.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    var lo = 255, hi = 0, maxChannel = 0
    for i in stride(from: 0, to: data.count, by: 4) {
        let l = (Int(data[i]) + Int(data[i + 1]) + Int(data[i + 2])) / 3
        lo = min(lo, l); hi = max(hi, l); maxChannel = max(maxChannel, Int(data[i]), Int(data[i + 1]), Int(data[i + 2]))
    }
    return "luminance \(lo)...\(hi), brightest channel \(maxChannel), corner pixel rgb \(data[0]),\(data[1]),\(data[2])"
}

if #available(macOS 14.0, *) {
    Task {
        for n in 1...4 {
            print("sample \(n):", (try? await sample()) ?? "capture refused")
            if n < 4 { try? await Task.sleep(nanoseconds: 20_000_000_000) }
        }
        exit(0)
    }
    RunLoop.main.run()
}
