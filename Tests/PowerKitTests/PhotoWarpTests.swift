import XCTest
@testable import PowerKit

/// The photo straightening: a homography, then a right-wall correction. The
/// expected values here are computed in the test by applying the mockup's `WP()`
/// formula independently, with the mockup's own (rounded) constants.
final class PhotoWarpTests: XCTestCase {

    // The constants as the mockup writes them (WARP in mockup-source.html).
    private let mockH: [Double] = [0.519715583, 0.007629929, -27.727457298,
                                   0.008782331, 0.515148464, -33.48119868,
                                   8.203e-06, 4.491e-06, 1.0]
    private let mockK = 3415.0 / 2296.0
    private let mockRA = 1668.0
    private let mockRB = 0.0244
    private let mockRR = 1696.402

    /// The mockup's `WP(px, py)`, written out again here.
    private func mockupWP(_ px: Double, _ py: Double) -> (Double, Double) {
        let X = px * mockK
        let Y = py * mockK
        let d = mockH[6] * X + mockH[7] * Y + mockH[8]
        let u = (mockH[0] * X + mockH[1] * Y + mockH[2]) / d
        let v = (mockH[3] * X + mockH[4] * Y + mockH[5]) / d
        return (u * mockRR / (mockRA + mockRB * v), v)
    }

    func testKnownPointsMatchTheMockup() {
        for (px, py) in [(434.0, 488.0), (1845.0, 481.0)] {
            let expected = mockupWP(px, py)
            let got = PhotoWarp.straightened.map(photoX: px, photoY: py)
            XCTAssertEqual(got.x, expected.0, accuracy: 0.5, "x at \(px), \(py)")
            XCTAssertEqual(got.y, expected.1, accuracy: 0.5, "y at \(px), \(py)")
        }
    }

    func testMappedPointsLandInsideTheStraightenedPhoto() {
        // The two fan centres sit well inside the 1700 x 1165 picture.
        for (px, py) in [(434.0, 488.0), (1845.0, 481.0)] {
            let p = PhotoWarp.straightened.map(photoX: px, photoY: py)
            XCTAssertGreaterThan(p.x, 0)
            XCTAssertLessThan(p.x, 1700)
            XCTAssertGreaterThan(p.y, 0)
            XCTAssertLessThan(p.y, 1165)
        }
    }

    /// The inverse of a 3 x 3 matrix given row by row (adjugate over determinant).
    private func inverse(_ m: [Double]) -> [Double] {
        let a = m[0], b = m[1], c = m[2]
        let d = m[3], e = m[4], f = m[5]
        let g = m[6], h = m[7], i = m[8]
        let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        return [(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det,
                (f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det,
                (d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det]
    }

    func testRightWallIsVerticalAfterCorrection() {
        // The fitted right wall, after the homography, is the line
        // u = RA + RB * v, which leans. Walk down it, send each point back to
        // original photo pixels with the inverse homography, and map it
        // forward again: the second pass must put every one at the same x.
        let inv = inverse(mockH)
        var xs: [Double] = []
        for v in [0.0, 300.0, 600.0, 900.0, 1165.0] {
            let u = mockRA + mockRB * v
            let w = inv[6] * u + inv[7] * v + inv[8]
            let X = (inv[0] * u + inv[1] * v + inv[2]) / w
            let Y = (inv[3] * u + inv[4] * v + inv[5]) / w
            let p = PhotoWarp.straightened.map(photoX: X / mockK, photoY: Y / mockK)
            xs.append(p.x)
            XCTAssertEqual(p.y, v, accuracy: 0.5, "the wall point keeps its row")
        }
        let lo = xs.min()!
        let hi = xs.max()!
        XCTAssertLessThan(hi - lo, 1.0, "wall x values: \(xs)")
        XCTAssertEqual(xs[0], mockRR, accuracy: 1.0)
    }

    func testDrawingUnitsFollowTheMockupsPhotoFrame() {
        let w = PhotoWarp.straightened
        let s = 1020.0 / 1700.0
        let expected = mockupWP(434, 488)
        let p = w.drawingPoint(photoX: 434, photoY: 488)
        XCTAssertEqual(p.x, 40 + expected.0 * s, accuracy: 0.5)
        XCTAssertEqual(p.y, 468 + expected.1 * s, accuracy: 0.5)
        // PS(126) = 126 * K * (1700 / 3362) * (1020 / 1700)
        XCTAssertEqual(w.drawingLength(126), 126 * mockK * (1700.0 / 3362.0) * s, accuracy: 0.01)
        XCTAssertEqual(w.frameHeight, 1165 * s, accuracy: 0.0001)
    }
}
