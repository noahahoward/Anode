import AppKit
import ImageIO
import PowerKit

/// A still image on one display. Costs nothing at runtime: it never plays or pauses.
///
/// Drawn from a copy decoded no larger than it needs to be (ImageIO downsamples while decoding, so a 100-megapixel photo costs
/// about one screen's worth of memory, not 400 MB), decoded off the main thread.
final class ImageWallpaperSurface: WallpaperSurface {

    let displayUUID: String
    let pausable = false
    var onCoveredChange: ((Bool) -> Void)?
    var onFailure: ((String) -> Void)?
    /// Called on the main thread when the decoded picture is in place.
    var onLoaded: (() -> Void)?

    let window: DesktopWallpaperWindow
    private let contentLayerView: NSView
    private let url: URL
    private let displayPixels: CGSize
    private let present: Bool
    private var scaling: WallpaperScaling
    private var generation = 0
    private var closed = false
    /// The decoded picture currently on the layer.
    private(set) var image: CGImage?

    static func gravity(for scaling: WallpaperScaling) -> CALayerContentsGravity {
        switch scaling {
        case .fill:    return .resizeAspectFill
        case .fit:     return .resizeAspect
        case .stretch: return .resize
        }
    }

    /// How large to decode, as the longer side in pixels: just enough that the picture fills the display the way `scaling`
    /// draws it (a tall phone photo on a wide screen is drawn larger than the screen's long side, so it needs more than that),
    /// never more than the picture itself, and never more than twice the display's pixel count.
    static func targetMaxPixel(imageSize: CGSize, displayPixels: CGSize, scaling: WallpaperScaling) -> Int {
        guard imageSize.width > 0, imageSize.height > 0 else { return Int(max(displayPixels.width, displayPixels.height)) }
        let sx = displayPixels.width / imageSize.width, sy = displayPixels.height / imageSize.height
        var scale = scaling == .fit ? min(sx, sy) : max(sx, sy)
        scale = min(scale, 1)
        // Memory ceiling: decoded area at most 2x the display's.
        let area = imageSize.width * imageSize.height * scale * scale
        let ceiling = 2 * displayPixels.width * displayPixels.height
        if area > ceiling { scale *= (ceiling / area).squareRoot() }
        return max(1, Int((max(imageSize.width, imageSize.height) * scale).rounded(.up)))
    }

    static func pixelSize(of url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Double, let h = props[kCGImagePropertyPixelHeight] as? Double else { return nil }
        return CGSize(width: w, height: h)
    }

    /// The picture, decoded no larger than `maxPixel` on its longer side, with its orientation applied.
    static func downsample(url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    init(display: DisplayInfo, item: WallpaperItem, library: WallpaperLibrary, scaling: WallpaperScaling, present: Bool = true) throws {
        guard let url = library.contentURL(item) else { throw WallpaperSurfaceError.missingFile(item.name) }
        self.displayUUID = display.uuid
        self.url = url
        self.displayPixels = display.pixelSize
        self.scaling = scaling
        self.present = present
        window = DesktopWallpaperWindow(frame: display.frame)
        contentLayerView = NSView(frame: NSRect(origin: .zero, size: display.frame.size))
        contentLayerView.wantsLayer = true
        contentLayerView.autoresizingMask = [.width, .height]
        contentLayerView.layer?.backgroundColor = NSColor.black.cgColor
        contentLayerView.layer?.contentsGravity = Self.gravity(for: scaling)
        window.contentView = contentLayerView
        window.onVisibilityChange = { [weak self] visible in self?.onCoveredChange?(!visible) }
    }

    deinit { close() }

    func start() { decode() }

    private func decode() {
        generation += 1
        let mine = generation
        let url = self.url, displayPixels = self.displayPixels, scaling = self.scaling
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let size = Self.pixelSize(of: url)
            let target = Self.targetMaxPixel(imageSize: size ?? displayPixels, displayPixels: displayPixels, scaling: scaling)
            let decoded = Self.downsample(url: url, maxPixel: target)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.closed, mine == self.generation else { return }
                guard let decoded else { self.onFailure?("That image can't be read."); return }
                self.image = decoded
                self.contentLayerView.layer?.contents = decoded
                if self.present { self.window.present() }
                self.onLoaded?()
            }
        }
    }

    /// An image has no playing state.
    func setPlaying(_ playing: Bool) {}

    func apply(_ prefs: WallpaperPrefs) {
        guard !closed else { return }
        contentLayerView.layer?.contentsGravity = Self.gravity(for: prefs.scaling)
        if prefs.scaling != scaling {
            scaling = prefs.scaling
            // The right decode size depends on the scaling, so a change decodes again (the old picture stays up meanwhile).
            if image != nil { decode() }
        }
    }

    func updateFrame(_ frame: NSRect) {
        guard !closed else { return }
        window.setFrame(frame, display: false)
    }

    func close() {
        guard !closed else { return }
        closed = true
        generation += 1
        contentLayerView.layer?.contents = nil
        image = nil
        window.dismiss()
        onCoveredChange = nil
        onFailure = nil
        onLoaded = nil
    }
}
