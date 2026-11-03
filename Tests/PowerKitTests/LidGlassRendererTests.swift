import XCTest
import AppKit
import Metal
@testable import AnodeApp

/// The glass shader, rendered to an image so it can be measured. No window is shown.
final class LidGlassRendererTests: XCTestCase {

    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private func makeImage(width: Int, height: Int, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let (r, g, b) = pixel(x, y); let i = (y * width + x) * 4
            bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b
        } }
        let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    private func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    private func renderer(for image: CGImage) throws -> LidGlassRenderer {
        guard let r = LidGlassRenderer() else { throw XCTSkip("no Metal device") }
        r.setImage(image)
        return r
    }

    /// Mean absolute difference between neighbouring pixels' green over rows `rows` — high for sharp, low for frosted.
    private func contrast(_ bytes: [UInt8], width: Int, rows: Range<Int>) -> Double {
        var total = 0.0, n = 0.0
        for y in rows { for x in 0..<(width - 1) {
            let i = (y * width + x) * 4 + 1
            total += abs(Double(bytes[i]) - Double(bytes[i + 4])); n += 1
        } }
        return total / n
    }

    private var checkerboard: CGImage {
        makeImage(width: 256, height: 160) { x, y in ((x / 4 + y / 4) % 2 == 0) ? (255, 255, 255) : (0, 0, 0) }
    }

    /// The spec's "invisible swap": with no frost the overlay must be the picture it was given, pixel for pixel.
    func testZeroBlurReproducesTheInputWithinOneLevel() throws {
        let input = makeImage(width: 256, height: 160) { x, y in
            (UInt8(x % 256), UInt8((y * 3) % 256), UInt8(((x / 8) % 2 == 0) ? 255 : 20))
        }
        let out = try XCTUnwrap(try renderer(for: input).renderOffscreen(blur: 0))
        XCTAssertEqual(out.width, 256); XCTAssertEqual(out.height, 160)
        let a = rgba(input), b = rgba(out)
        var worst = 0
        for i in 0..<a.count { worst = max(worst, abs(Int(a[i]) - Int(b[i]))) }
        XCTAssertLessThanOrEqual(worst, 1)
    }

    func testBlurIsStrongerAwayFromTheHinge() throws {
        let out = try XCTUnwrap(try renderer(for: checkerboard).renderOffscreen(blur: 1))
        let b = rgba(out)
        let top = contrast(b, width: 256, rows: 0..<16)
        let bottom = contrast(b, width: 256, rows: 144..<160)
        XCTAssertGreaterThan(bottom, top * 2, "top \(top) bottom \(bottom)")
    }

    func testBlurAmountOrdersByStrength() throws {
        let r = try renderer(for: checkerboard)
        let c = try [0.0, 0.25, 0.75, 1.0].map { amount -> Double in
            contrast(rgba(try XCTUnwrap(r.renderOffscreen(blur: amount))), width: 256, rows: 0..<160)
        }
        XCTAssertGreaterThan(c[0], c[1]); XCTAssertGreaterThan(c[1], c[2]); XCTAssertGreaterThan(c[2], c[3])
    }

    func testRenderIsDeterministic() throws {
        let r = try renderer(for: checkerboard)
        XCTAssertEqual(rgba(try XCTUnwrap(r.renderOffscreen(blur: 0.6))), rgba(try XCTUnwrap(r.renderOffscreen(blur: 0.6))))
    }

    func testRenderingBeforeAnImageIsSetGivesNothing() throws {
        guard let r = LidGlassRenderer() else { throw XCTSkip("no Metal device") }
        XCTAssertNil(r.renderOffscreen(blur: 0.5))
    }

    /// The harness for tuning: `LIDGLASS_DUMP=<dir> LIDGLASS_IMAGE=<png> swift test --filter ...testWritesReferenceFrames`.
    func testWritesReferenceFramesWhenAsked() throws {
        guard let dir = ProcessInfo.processInfo.environment["LIDGLASS_DUMP"],
              let path = ProcessInfo.processInfo.environment["LIDGLASS_IMAGE"] else { throw XCTSkip("LIDGLASS_DUMP not set") }
        let src = try XCTUnwrap(NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let r = try renderer(for: src)
        for blur in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let img = try XCTUnwrap(r.renderOffscreen(blur: blur))
            let rep = NSBitmapImageRep(cgImage: img)
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("frame-\(blur).png"))
        }
    }
}
