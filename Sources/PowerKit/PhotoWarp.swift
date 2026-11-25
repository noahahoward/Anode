import Foundation

/// Maps positions read off the original teardown photo onto the straightened
/// photo, and from there into the Hardware view's drawing units.
///
/// The stand-in photo was straightened in two passes: a homography (`H`) that
/// squares the chassis, then `u' = u * RR / (RA + RB * v)` that squares the
/// right wall, which still leaned after the first pass. Every overlay position
/// in the layout is written in the ORIGINAL photo's pixels as shown 2296 wide;
/// `map` puts it on the 1700 x 1165 straightened picture. The constants come
/// from `docs/superpowers/hardware-view-assets/warp.json`.
public struct PhotoWarp {
    /// The 3 x 3 homography, row by row.
    public let homography: [Double]
    /// Converts the 2296-wide display coordinates to the 3415-wide original.
    public let displayToOriginal: Double
    public let wallA: Double
    public let wallB: Double
    public let wallR: Double

    /// Width and height of the straightened photo in its own pixels.
    public let outputWidth: Double
    public let outputHeight: Double
    /// Maps a length in display pixels to straightened pixels (1700 / 3362).
    public let lengthScale: Double

    /// Where the straightened photo sits in the drawing: x 40, y 468, 1020 wide.
    public static let frameX: Double = 40
    public static let frameY: Double = 468
    public static let frameWidth: Double = 1020

    public static let straightened = PhotoWarp(
        homography: [0.5197155831892581, 0.007629929405049585, -27.72745729786491,
                     0.008782330866062478, 0.5151484642216404, -33.48119867969634,
                     8.203168497796915e-06, 4.490835435579509e-06, 1.0],
        displayToOriginal: 1.487369337979094,
        wallA: 1668.0,
        wallB: 0.0244,
        wallR: 1696.4016,
        outputWidth: 1700,
        outputHeight: 1165,
        lengthScale: 1700.0 / 3362.0)

    public init(homography: [Double], displayToOriginal: Double,
                wallA: Double, wallB: Double, wallR: Double,
                outputWidth: Double, outputHeight: Double, lengthScale: Double) {
        self.homography = homography
        self.displayToOriginal = displayToOriginal
        self.wallA = wallA
        self.wallB = wallB
        self.wallR = wallR
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.lengthScale = lengthScale
    }

    /// One straightened-photo pixel is this many drawing units (1020 / 1700).
    public var frameScale: Double { PhotoWarp.frameWidth / outputWidth }

    /// The photo's height in drawing units (1165 * 1020 / 1700 = 699).
    public var frameHeight: Double { outputHeight * frameScale }

    /// Original-photo display pixels (2296 wide) to straightened-photo pixels
    /// (1700 x 1165).
    public func map(photoX: Double, photoY: Double) -> HWPoint {
        let X = photoX * displayToOriginal
        let Y = photoY * displayToOriginal
        let h = homography
        let d = h[6] * X + h[7] * Y + h[8]
        let u = (h[0] * X + h[1] * Y + h[2]) / d
        let v = (h[3] * X + h[4] * Y + h[5]) / d
        return HWPoint(x: u * wallR / (wallA + wallB * v), y: v)
    }

    /// Original-photo display pixels to drawing units (the mockup's `P()`).
    public func drawingPoint(photoX: Double, photoY: Double) -> HWPoint {
        let p = map(photoX: photoX, photoY: photoY)
        return HWPoint(x: PhotoWarp.frameX + p.x * frameScale,
                       y: PhotoWarp.frameY + p.y * frameScale)
    }

    /// A length in original-photo display pixels to drawing units (the
    /// mockup's `PS()`).
    public func drawingLength(_ photoLength: Double) -> Double {
        photoLength * displayToOriginal * lengthScale * frameScale
    }
}
