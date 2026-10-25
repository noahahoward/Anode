import AppKit
import ScreenCaptureKit

// ── Reading another window's top edge ───────────────────────────────────────
//
// The menu bar strip can take its colour from the window beneath it. For Anode's
// own windows that needs nothing (see `MenuBarBackdrop.topEdgeColor`); for any
// other app's, macOS allows it only with Screen Recording permission, which is
// what this file is for and the only place that touches it.
//
// What is read is deliberately small: a strip of a few pixels, just under the bar,
// reduced to a row of colours. It is never stored and never leaves the process.

enum ScreenRecordingAccess {

    /// Is permission already granted? Never prompts.
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Put macOS's question to the user. Shows the system dialog the first time
    /// and does nothing visible after a refusal — a refusal is then changed only in
    /// System Settings, which `openSettings` goes to.
    @discardableResult
    static func request() -> Bool { CGRequestScreenCaptureAccess() }

    static func openSettings() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum WindowEdgeSampler {

    /// `columns` colours across `rect`, left to right, or nil when the capture is
    /// refused or fails. `rect` is in the display's own points, origin top-left.
    ///
    /// ScreenCaptureKit's one-shot screenshot arrived in macOS 14 and the package
    /// still targets 13, so on 13 there is simply nothing to read.
    static func colors(onDisplay displayID: CGDirectDisplayID, rect: CGRect,
                       columns: Int) async -> [NSColor]? {
        guard #available(macOS 14.0, *), ScreenRecordingAccess.isGranted else { return nil }
        do {
            guard let display = try await display(for: displayID) else { return nil }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.sourceRect = rect
            // At the strip's own resolution, NOT squeezed into `columns` x 2 pixels: the
            // system keeps the aspect ratio when it scales, so a 1766 x 6 pt strip asked
            // for as 48 x 2 arrived as a sliver of one row with the rest transparent,
            // and the colours came back premultiplied by that coverage — about half as
            // bright as the real screen. Averaging is done here instead.
            config.width = max(1, Int(rect.width * 2))
            config.height = max(1, Int(rect.height * 2))
            config.showsCursor = false
            config.pixelFormat = kCVPixelFormatType_32BGRA
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                  configuration: config)
            return rowColors(of: image, columns: columns)
        } catch {
            return nil
        }
    }

    /// The display list is a system round trip, and the answer only changes when a
    /// screen does.
    @available(macOS 14.0, *)
    private static func display(for id: CGDirectDisplayID) async throws -> SCDisplay? {
        if let hit = cache.first(where: { $0.displayID == id }) { return hit }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        cache = content.displays
        return cache.first { $0.displayID == id }
    }
    @available(macOS 14.0, *)
    private static var cache: [SCDisplay] {
        get { _cache as? [SCDisplay] ?? [] }
        set { _cache = newValue }
    }
    private static var _cache: Any?

    /// Forget the cached display list, after a screen was added, removed or changed.
    static func forgetDisplays() { _cache = nil }

    /// `columns` colours across the image, each the mean of its block of pixels.
    ///
    /// The captured pixels are premultiplied by alpha, so each mean is the summed
    /// colour divided by the summed alpha, not by 255: dividing by 255 read every
    /// colour darker by the image's own transparency, and the bar then came out
    /// darker than the window it was meant to match (measured: 0.99 on screen, 0.31
    /// decoded that way).
    static func rowColors(of image: CGImage, columns: Int) -> [NSColor]? {
        guard image.width > 0, image.height > 0, columns > 0 else { return nil }
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var out: [NSColor] = []
        for column in 0..<columns {
            let x0 = column * w / columns
            let x1 = max(x0 + 1, (column + 1) * w / columns)
            var r = 0.0, g = 0.0, b = 0.0, a = 0.0
            for y in 0..<h {
                for x in x0..<min(x1, w) {
                    let i = (y * w + x) * 4
                    r += Double(bytes[i]); g += Double(bytes[i + 1]); b += Double(bytes[i + 2])
                    a += Double(bytes[i + 3])
                }
            }
            // Nothing there at all: no honest colour to report for this column.
            guard a > 0 else { return nil }
            out.append(NSColor(srgbRed: min(1, r / a), green: min(1, g / a), blue: min(1, b / a), alpha: 1))
        }
        return out
    }
}
