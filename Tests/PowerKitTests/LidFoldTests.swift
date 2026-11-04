import XCTest
import simd
@testable import PowerKit

/// The geometry of the fold: the picture is frozen in the room while the glass tilts in front of it.
final class LidFoldTests: XCTestCase {

    private let w = 1512.0, h = 982.0

    private func corners(start: Double = 90, angle: Double, look: LidFoldLook = .init(startAngle: 90)) -> [LidPoint] {
        LidFoldGeometry.corners(screenWidth: w, screenHeight: h, startAngle: start, angle: angle, look: look)
    }

    func testAtTheStartAngleTheCornersAreTheScreen() {
        let c = corners(angle: 90)
        let screen = [LidPoint(x: 0, y: 0), LidPoint(x: w, y: 0), LidPoint(x: w, y: h), LidPoint(x: 0, y: h)]
        for (a, b) in zip(c, screen) {
            XCTAssertEqual(a.x, b.x, accuracy: 1e-6); XCTAssertEqual(a.y, b.y, accuracy: 1e-6)
        }
    }

    func testAboveTheStartAngleItIsStillFlat() {
        let c = corners(angle: 120)
        XCTAssertEqual(c[2].y, h, accuracy: 1e-6)
    }

    func testTheHingeEdgeStaysPutWhileTheFarEdgeNarrowsAndRecedes() {
        let c = corners(angle: 60)
        XCTAssertEqual(c[0].x, 0, accuracy: 1e-6); XCTAssertEqual(c[0].y, 0, accuracy: 1e-6)
        XCTAssertEqual(c[1].x, w, accuracy: 1e-6); XCTAssertEqual(c[1].y, 0, accuracy: 1e-6)
        XCTAssertLessThan(c[2].x - c[3].x, w, "the far edge converges, as a plane leaning away does")
        XCTAssertNotEqual(c[2].y, h, accuracy: 1, "the far edge has moved on the glass")
    }

    /// The glass is a lens over a picture that stays where it was: seen through it the picture is stretched
    /// vertically (left behind as the glass tips toward the keyboard) and hardly narrows. It should not look like
    /// the picture shrinking away.
    func testTheFoldStretchesTheContentVerticallyAndHardlyNarrowsIt() {
        let look = LidFoldLook(startAngle: 90)
        func corners(_ angle: Double) -> [LidPoint] {
            LidFoldGeometry.corners(screenWidth: w, screenHeight: h, startAngle: 90, angle: angle, look: look)
        }
        func topWidth(_ angle: Double) -> Double { let c = corners(angle); return (c[2].x - c[3].x) / w }
        func stretch(_ angle: Double) -> Double { corners(angle)[2].y / h }       // how far past the glass the picture's top lands
        XCTAssertGreaterThan(topWidth(60), 0.95)
        XCTAssertGreaterThan(topWidth(45), 0.90)
        XCTAssertGreaterThan(topWidth(30), 0.85)
        // The parallel-projection ideal is 1 / cos(travel): 1.41 at 45 degrees of fold, 2.0 at 60.
        XCTAssertGreaterThan(stretch(45), 1.30)
        XCTAssertGreaterThan(stretch(30), 1.75)
        XCTAssertLessThan(stretch(45), 1.5, "stretched, not exploded")
    }

    // ── The rim lens ──
    //
    // Along the glass's far edge the picture is looked up from further inside the screen, by an amount that falls to
    // nothing across the rim, so the content near the edge is seen flipped and compressed, as through the rim of a thick
    // lens, instead of simply fading.

    func testTheRimLensLooksFurtherInsideAtTheEdgeAndNothingBeyondTheRim() {
        let rim = 80.0
        XCTAssertEqual(LidGlassLens.offset(t: 0, rim: rim), LidGlassLens.depth * rim, accuracy: 1e-9)
        XCTAssertEqual(LidGlassLens.offset(t: rim, rim: rim), 0, accuracy: 1e-9)
        XCTAssertEqual(LidGlassLens.offset(t: rim + 50, rim: rim), 0)
        XCTAssertEqual(LidGlassLens.offset(t: 10, rim: 0), 0, "no rim, no lens")
    }

    /// Where the lookup lands, measured inward from the edge: t + offset(t). It must go back on itself near the edge.
    func testTheRimLensFoldsTheContentBackOnItself() {
        let rim = 80.0
        func inward(_ t: Double) -> Double { t + LidGlassLens.offset(t: t, rim: rim) }
        var reversed = false
        var previous = inward(0)
        for i in 1...160 {
            let now = inward(Double(i) * 0.5)
            if now < previous - 1e-9 { reversed = true }
            previous = now
        }
        XCTAssertTrue(reversed, "the lookup runs the wrong way for part of the rim")
        XCTAssertEqual(inward(rim), rim, accuracy: 1e-9, "and is back to an ordinary lookup at its inner edge")
    }

    func testTheHomographyMapsTheRectangleOntoTheCorners() {
        let c = corners(angle: 55)
        let m = LidHomography.matrix(width: w, height: h, to: c)
        let mapped = [LidPoint(x: 0, y: 0), LidPoint(x: w, y: 0), LidPoint(x: w, y: h), LidPoint(x: 0, y: h)]
            .map { LidHomography.apply(m, to: $0) }
        for (a, b) in zip(mapped, c) {
            XCTAssertEqual(a.x, b.x, accuracy: 1e-6); XCTAssertEqual(a.y, b.y, accuracy: 1e-6)
        }
        let back = LidHomography.apply(m.inverse, to: c[2])
        XCTAssertEqual(back.x, w, accuracy: 1e-6); XCTAssertEqual(back.y, h, accuracy: 1e-6)
    }

    func testTheCurveIsZeroAtTheStartAndOneAtFullStrength() {
        let curve = LidFoldCurve(startAngle: 90, span: 58)
        XCTAssertEqual(curve.progress(at: 100), 0)
        XCTAssertEqual(curve.progress(at: 90), 0)
        XCTAssertEqual(curve.progress(at: 32), 1, accuracy: 1e-9)
        XCTAssertEqual(curve.progress(at: 10), 1)
        XCTAssertEqual(curve.blurStrength(progress: 0), 0)
        XCTAssertEqual(curve.blurStrength(progress: 1), 1)
        XCTAssertLessThan(curve.blurStrength(progress: 0.5), 0.5, "frost starts gently")
        XCTAssertGreaterThan(curve.dimStrength(progress: 0.5), 0.5, "the dimming starts at once")
    }

    func testTheFrameAtTheStartAngleIsTheUntouchedPicture() {
        let f = LidFoldFrame.make(look: .init(startAngle: 90), screen: CGSize(width: w, height: h), angle: 90)
        XCTAssertEqual(f.blurStrength, 0); XCTAssertEqual(f.dimStrength, 0)
        XCTAssertEqual(f.topEdge, h, accuracy: 1e-6)
        XCTAssertEqual(f.blurFloor, 0, accuracy: 1e-9)
    }

    func testDeepIntoTheCloseTheHingeRowsFrostToo() {
        let f = LidFoldFrame.make(look: .init(startAngle: 90), screen: CGSize(width: w, height: h), angle: 10)
        XCTAssertGreaterThan(f.blurFloor, 0.5, "a near edge-on picture streaks unless the hinge rows are frosted")
        XCTAssertEqual(f.blurStrength, 1)
    }

    func testAnAngleFarBelowTheStartNeverGoesDegenerate() {
        for a in stride(from: 90.0, through: -5, by: -5) {
            for p in corners(angle: a) { XCTAssertTrue(p.x.isFinite && p.y.isFinite, "angle \(a)") }
        }
    }
}
