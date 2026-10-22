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
            // Scaled down by the system, which averages as it goes: a few hundred
            // columns of pixels arrive as `columns` already-blended ones.
            config.width = columns
            config.height = 2
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

    static func rowColors(of image: CGImage, columns: Int) -> [NSColor]? {
        guard image.width > 0, image.height > 0 else { return nil }
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
        return (0..<columns).map { column in
            let x = min(w - 1, column * w / columns)
            var r = 0.0, g = 0.0, b = 0.0
            for y in 0..<h {
                let i = (y * w + x) * 4
                r += Double(bytes[i]); g += Double(bytes[i + 1]); b += Double(bytes[i + 2])
            }
            let n = Double(h) * 255
            return NSColor(srgbRed: r / n, green: g / n, blue: b / n, alpha: 1)
        }
    }
}
