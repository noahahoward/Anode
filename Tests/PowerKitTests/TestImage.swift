import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes small real image files for the importer and the image surface.
enum TestImage {
    static func cgImage(width: Int, height: Int) -> CGImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        return ctx.makeImage()!
    }

    @discardableResult
    static func write(_ type: UTType, width: Int, height: Int, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, cgImage(width: width, height: height), nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    @discardableResult
    static func writePNG(width: Int = 64, height: Int = 48, to url: URL) throws -> URL { try write(.png, width: width, height: height, to: url) }

    @discardableResult
    static func writeJPEG(width: Int = 64, height: Int = 48, to url: URL) throws -> URL { try write(.jpeg, width: width, height: height, to: url) }

    /// An animated GIF (or APNG / WebP where the system can write one): `frames` frames, each shown for `delay` seconds.
    /// A `delay` of 0 writes a zero delay, which is what many real GIFs contain.
    @discardableResult
    static func writeAnimated(_ type: UTType = .gif, frames: Int, delay: Double, width: Int = 48, height: Int = 32, to url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, frames, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let key: CFString = type == .png ? kCGImagePropertyPNGDictionary : kCGImagePropertyGIFDictionary
        let delayKey: CFString = type == .png ? kCGImagePropertyAPNGDelayTime : kCGImagePropertyGIFDelayTime
        CGImageDestinationSetProperties(dest, [key: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for i in 0..<frames {
            let space = CGColorSpaceCreateDeviceRGB()
            let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(red: CGFloat(i % 5) / 5, green: 0.4, blue: 1 - CGFloat(i % 5) / 5, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            CGImageDestinationAddImage(dest, ctx.makeImage()!, [key: [delayKey: delay]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    /// The pixel size of an image file, or nil if it is not one.
    static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }
}
