import XCTest
import AppKit
import Metal
@testable import AnodeApp
@testable import PowerKit

/// The glass shader, rendered to an image so it can be measured. No window is shown.
final class LidGlassRendererTests: XCTestCase {

    private let space = CGColorSpace(name: LidGlassRenderer.colourSpaceName)!

    private func makeImage(width: Int, height: Int, _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let (r, g, b) = pixel(x, y); let i = (y * width + x) * 4
            bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b
        } }
        let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    private func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }

    private func renderer(for image: CGImage) throws -> LidGlassRenderer {
        guard let r = LidGlassRenderer() else { throw XCTSkip("no Metal device") }
        r.setImage(image, scale: 1)
        return r
    }

    private func frame(_ image: CGImage, angle: Double) -> LidFoldFrame {
        LidFoldFrame.make(look: LidFoldLook(startAngle: 90), screen: CGSize(width: image.width, height: image.height), angle: angle)
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
        let out = try XCTUnwrap(try renderer(for: input).renderOffscreen(frame(input, angle: 90)))
        XCTAssertEqual(out.width, 256); XCTAssertEqual(out.height, 160)
        let a = rgba(input), b = rgba(out)
        var worst = 0
        for i in 0..<a.count { worst = max(worst, abs(Int(a[i]) - Int(b[i]))) }
        XCTAssertLessThanOrEqual(worst, 1)
    }

    /// The frost alone, with the geometry held flat: the far (top) edge goes soft first, the hinge side stays sharper.
    func testBlurIsStrongerAwayFromTheHinge() throws {
        let board = checkerboard
        var f = frame(board, angle: 90)
        f.blurStrength = 1
        f.maxBlurRadius = 24
        let out = try XCTUnwrap(try renderer(for: board).renderOffscreen(f))
        let b = rgba(out)
        let top = contrast(b, width: 256, rows: 0..<16)
        let bottom = contrast(b, width: 256, rows: 144..<160)
        XCTAssertGreaterThan(bottom, top * 2, "top \(top) bottom \(bottom)")
    }

    func testBlurAmountOrdersByStrength() throws {
        let board = checkerboard
        let r = try renderer(for: board)
        let c = try [90.0, 75, 60, 40].map { angle -> Double in
            contrast(rgba(try XCTUnwrap(r.renderOffscreen(frame(board, angle: angle)))), width: 256, rows: 0..<160)
        }
        XCTAssertGreaterThan(c[0], c[1]); XCTAssertGreaterThan(c[1], c[2]); XCTAssertGreaterThan(c[2], c[3])
    }

    // ── Glass effects ──

    private func channelProfile(_ bytes: [UInt8], width: Int, x: Int, channel: Int, rows: Range<Int>) -> [Double] {
        rows.map { Double(bytes[($0 * width + x) * 4 + channel]) }
    }

    /// The row where a channel first falls below half of its own brightest value, going down a column.
    private func edgeRow(_ profile: [Double]) -> Int? {
        guard let top = profile.max(), top > 8 else { return nil }
        return profile.firstIndex { $0 < top / 2 }
    }

    /// Chromatic aberration: at a deep fold red and blue land on different rows; unfolded, they are the same.
    func testTheColoursSeparateAtADeepFoldAndNotAtAllUnfolded() throws {
        let image = makeImage(width: 256, height: 160) { _, y in y < 70 ? (255, 255, 255) : (0, 0, 0) }
        let r = try renderer(for: image)
        var look = LidFoldLook(startAngle: 90); look.blurRadius = 1
        func rows(_ angle: Double) throws -> (red: Int?, blue: Int?) {
            let f = LidFoldFrame.make(look: look, screen: CGSize(width: 256, height: 160), angle: angle)
            let b = rgba(try XCTUnwrap(r.renderOffscreen(f)))
            return (edgeRow(channelProfile(b, width: 256, x: 128, channel: 0, rows: 0..<160)),
                    edgeRow(channelProfile(b, width: 256, x: 128, channel: 2, rows: 0..<160)))
        }
        let flat = try rows(90)
        XCTAssertEqual(flat.red, flat.blue, "unfolded, nothing is fringed")
        let folded = try rows(50)
        let red = try XCTUnwrap(folded.red), blue = try XCTUnwrap(folded.blue)
        XCTAssertGreaterThanOrEqual(abs(red - blue), 4, "red at \(red), blue at \(blue)")
    }

    /// The thin edge light along the glass's far edge, on a black picture: there at a fold, gone when unfolded.
    func testAThinLightRunsAlongTheFarEdgeOfTheGlassWhenFolded() throws {
        let black = makeImage(width: 256, height: 160) { _, _ in (0, 0, 0) }
        let r = try renderer(for: black)
        func level(_ angle: Double, row: Int) throws -> Double {
            let b = rgba(try XCTUnwrap(r.renderOffscreen(frame(black, angle: angle))))
            return channelProfile(b, width: 256, x: 128, channel: 2, rows: row..<(row + 1))[0]
        }
        XCTAssertEqual(try level(90, row: 1), 0)
        XCTAssertGreaterThan(try level(50, row: 1), try level(50, row: 40) + 4)
    }

    func testRenderIsDeterministic() throws {
        let board = checkerboard
        let r = try renderer(for: board)
        let f = frame(board, angle: 60)
        XCTAssertEqual(rgba(try XCTUnwrap(r.renderOffscreen(f))), rgba(try XCTUnwrap(r.renderOffscreen(f))))
    }

    func testRenderingBeforeAnImageIsSetGivesNothing() throws {
        guard let r = LidGlassRenderer() else { throw XCTSkip("no Metal device") }
        XCTAssertNil(r.renderOffscreen(frame(checkerboard, angle: 60)))
    }

    /// The harness for tuning: `LIDGLASS_DUMP=<dir> LIDGLASS_IMAGE=<png> swift test --filter ...testWritesReferenceFrames`.
    func testWritesReferenceFramesWhenAsked() throws {
        guard let dir = ProcessInfo.processInfo.environment["LIDGLASS_DUMP"],
              let path = ProcessInfo.processInfo.environment["LIDGLASS_IMAGE"] else { throw XCTSkip("LIDGLASS_DUMP not set") }
        let src = try XCTUnwrap(NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let r = try renderer(for: src)
        for angle in [90.0, 80, 70, 60, 50, 40, 30] {
            let img = try XCTUnwrap(r.renderOffscreen(LidFoldFrame.make(look: LidFoldLook(startAngle: 90),
                                       screen: CGSize(width: src.width, height: src.height), angle: angle)))
            let rep = NSBitmapImageRep(cgImage: img)
            try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: dir).appendingPathComponent("frame-\(Int(angle)).png"))
        }
    }
}
