import AppKit
import ScreenCaptureKit

// ── Lid Glass: the picture that gets frosted ────────────────────────────────
//
// One screenshot of the built-in display, taken when the lid starts to close. It is what the frost is drawn
// over, so it must match the live screen pixel for pixel (same size, same format, no cursor) or the swap
// from live screen to overlay would show. Every capture's time is logged, because whether the picture can be
// taken at the trigger or must be taken ahead of it is decided by that number.

enum LidGlassCapture {

    /// The Mac's own screen, if it has one that is on.
    static func builtInDisplayID() -> CGDirectDisplayID? {
        for screen in NSScreen.screens {
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = CGDirectDisplayID(n.uint32Value)
            if CGDisplayIsBuiltin(id) != 0 { return id }
        }
        return nil
    }

    /// Whether a screen other than the built-in one is attached. The effect is for the built-in display alone.
    static func hasExternalDisplay() -> Bool {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }

    @available(macOS 14.0, *)
    static func configuration(pointSize: CGSize, scale: CGFloat) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = Int((pointSize.width * scale).rounded())
        config.height = Int((pointSize.height * scale).rounded())
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        return config
    }

    /// The display as it is now, without the windows in `excludingWindowIDs` (the overlay's own), or nil when
    /// Screen Recording is not allowed or the capture fails.
    @available(macOS 14.0, *)
    static func capture(displayID: CGDirectDisplayID,
                        excludingWindowIDs: [CGWindowID]) async -> (image: CGImage, seconds: Double)? {
        guard ScreenRecordingAccess.isGranted else { return nil }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
            let excluded = content.windows.filter { excludingWindowIDs.contains($0.windowID) }
            let filter = SCContentFilter(display: display, excludingWindows: excluded)
            let pixelsWide = CGDisplayCopyDisplayMode(displayID)?.pixelWidth ?? display.width
            let scale = max(1, CGFloat(pixelsWide) / CGFloat(max(display.width, 1)))
            let config = configuration(pointSize: CGSize(width: display.width, height: display.height), scale: scale)
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let seconds = ProcessInfo.processInfo.systemUptime - started
            FeatureLog.append("lidglass.log", String(format: "capture %.1f ms %dx%d", seconds * 1000, image.width, image.height))
            return (image, seconds)
        } catch {
            FeatureLog.append("lidglass.log", "capture failed: \(error.localizedDescription)")
            return nil
        }
    }
}
