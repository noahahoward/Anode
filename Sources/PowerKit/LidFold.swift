import Foundation
import simd

// ── Lid Glass: the geometry of the fold ─────────────────────────────────────
//
// The picture is frozen in the room at the moment the effect starts. The lid keeps turning, and every pixel of
// the glass shows what a fixed eye would see of that frozen picture THROUGH the glass: the picture holds still
// while the MacBook folds around it. That is the iPhone Duo transition, and it is a projective map, not a blur.
//
// This file adapts the model of Mac Duo (github.com/ninobc/mac-duo, FoldGeometry / Homography / FoldCurve),
// which is MIT licensed:
//
//   MIT License — Copyright (c) 2026 Nino Bouchedid
//   Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
//   documentation files (the "Software"), to deal in the Software without restriction, including without
//   limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the
//   Software, and to permit persons to whom the Software is furnished to do so, subject to the following
//   conditions: The above copyright notice and this permission notice shall be included in all copies or
//   substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
//
// Screen points have their origin at the bottom-left, the hinge edge; y grows toward the top of the lid.

public struct LidPoint: Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// Everything that shapes the look. One value, so the look is a single thing to hand around and to tune.
public struct LidFoldLook: Equatable {
    /// The angle the picture was frozen at.
    public var startAngle: Double
    /// Degrees of further closing to reach full strength.
    public var span = 58.0
    /// Blur radius at the far edge at full strength, in points.
    public var blurRadius = 125.0
    /// How dark the far edge goes, 0...1.
    public var dimming = 1.0
    /// Height, as a share of the screen, where the dimming reaches full strength.
    public var dimReach = 0.55
    /// Dimming at the hinge as a share of the far edge, so the whole picture sinks a little as it folds.
    public var dimHingeFloor = 0.18
    /// Eye distance from the screen's middle, in screen heights. Closer means stronger perspective.
    /// (Mac Duo's default is 2.4, which narrows the far edge to 66% of the width at 45 degrees of fold; this is 3.5,
    /// 75%. 5 would be 82%, a stronger "stays in place" and less of the trapezoid.)
    public var eyeDistance = 3.5
    /// Eye height above the screen's middle, in screen heights.
    public var eyeHeight = 0.0
    /// How much the picture stays fixed in the room: 1 is physically right.
    public var depth = 1.0
    /// Exponents on the progress: above 1 starts gently.
    public var blurExponent = 1.55
    public var dimExponent = 0.75

    public init(startAngle: Double) { self.startAngle = startAngle }
}

public enum LidFoldGeometry {

    /// The picture never turns past this far from the glass, so it cannot go edge-on or behind the eye.
    public static let maximumSeparation = 88.0

    /// Where the four corners of the frozen picture land on the glass when the lid is at `angle`, ordered
    /// bottom-left, bottom-right, top-right, top-left. At the start angle (or above it) this is exactly the
    /// screen rectangle; folding past it the far edge recedes and the sides converge, as a plane leaning away does.
    public static func corners(screenWidth width: Double, screenHeight height: Double, startAngle: Double,
                               angle: Double, look: LidFoldLook) -> [LidPoint] {
        let travel = max(startAngle - angle, 0)
        let separation = min(look.depth * travel, maximumSeparation)
        let pictureAngle = angle + separation
        let lid = angle * .pi / 180
        let pic = pictureAngle * .pi / 180
        let start = startAngle * .pi / 180

        // The eye: in front of the screen's middle at the start pose.
        let centre = (y: height / 2 * sin(start), z: height / 2 * cos(start))
        let normal = (y: -cos(start), z: sin(start))
        let reach = look.eyeDistance * height
        let lift = look.eyeHeight * height
        let up = (y: sin(start), z: cos(start))
        let eye = (x: width / 2,
                   y: centre.y + normal.y * reach + up.y * lift,
                   z: centre.z + normal.z * reach + up.z * lift)

        // The glass plane through the hinge, with normal n(lid).
        let n = (y: -cos(lid), z: sin(lid))
        let nDotEye = n.y * eye.y + n.z * eye.z

        func project(_ px: Double, _ ph: Double) -> LidPoint {
            let q = (x: px, y: ph * sin(pic), z: ph * cos(pic))
            let d = (x: q.x - eye.x, y: q.y - eye.y, z: q.z - eye.z)
            let nDotD = n.y * d.y + n.z * d.z
            let t = abs(nDotD) < 1e-9 ? 1 : max(-nDotEye / nDotD, 1e-3)
            let hit = (x: eye.x + t * d.x, y: eye.y + t * d.y, z: eye.z + t * d.z)
            return LidPoint(x: hit.x, y: hit.y * sin(lid) + hit.z * cos(lid))
        }
        return [project(0, 0), project(width, 0), project(width, height), project(0, height)]
    }
}

/// The projective map from the picture rectangle to the quadrilateral it lands on: `screen = M * (x, y, 1)`,
/// then divide by z.
public enum LidHomography {

    /// Maps (0,0)...(width,height) onto `corners` (Heckbert's square-to-quad, with the rectangle folded in).
    public static func matrix(width: Double, height: Double, to corners: [LidPoint]) -> simd_double3x3 {
        precondition(corners.count == 4, "a quad has four corners")
        let (x0, y0) = (corners[0].x, corners[0].y)
        let (x1, y1) = (corners[1].x, corners[1].y)
        let (x2, y2) = (corners[2].x, corners[2].y)
        let (x3, y3) = (corners[3].x, corners[3].y)

        let dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3
        let dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3

        var g = 0.0, h = 0.0
        if abs(dx3) > 1e-10 || abs(dy3) > 1e-10 {
            let det = dx1 * dy2 - dx2 * dy1
            if abs(det) > 1e-12 {
                g = (dx3 * dy2 - dx2 * dy3) / det
                h = (dx1 * dy3 - dx3 * dy1) / det
            }
        }
        let a = x1 - x0 + g * x1, b = x3 - x0 + h * x3, c = x0
        let d = y1 - y0 + g * y1, e = y3 - y0 + h * y3, f = y0
        return simd_double3x3(columns: (
            SIMD3(a / width, d / width, g / width),
            SIMD3(b / height, e / height, h / height),
            SIMD3(c, f, 1)))
    }

    public static func apply(_ m: simd_double3x3, to p: LidPoint) -> LidPoint {
        let v = m * SIMD3(p.x, p.y, 1)
        return LidPoint(x: v.x / v.z, y: v.y / v.z)
    }
}

/// How far along the fold we are and how strong each part of the look is. A function of the lid angle alone, so
/// opening simply runs it backwards.
public struct LidFoldCurve {
    public var startAngle: Double
    public var span: Double
    public var blurExponent = 1.55
    public var dimExponent = 0.75

    public init(startAngle: Double, span: Double) {
        self.startAngle = startAngle
        self.span = max(span, 1)
    }

    /// 0 at the start angle and above, 1 at full strength, linear in the angle between.
    public func progress(at angle: Double) -> Double {
        min(max((startAngle - angle) / span, 0), 1)
    }

    public func blurStrength(progress: Double) -> Double { pow(min(max(progress, 0), 1), blurExponent) }
    public func dimStrength(progress: Double) -> Double { pow(min(max(progress, 0), 1), dimExponent) }

    public static func smoothstep(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        return x * x * (3 - 2 * x)
    }
}

/// Everything the shader needs for one frame, apart from the picture.
public struct LidFoldFrame {
    public var corners: [LidPoint]
    public var blurStrength: Double
    public var dimStrength: Double
    public var blurFloor: Double
    public var maxDim: Double
    public var maxBlurRadius: Double
    public var dimReach: Double
    public var dimHingeFloor: Double
    /// Where the picture's far edge lands on the glass, in points.
    public var topEdge: Double

    public static func make(look: LidFoldLook, screen: CGSize, angle: Double) -> LidFoldFrame {
        let width = Double(screen.width), height = Double(screen.height)
        var curve = LidFoldCurve(startAngle: look.startAngle, span: look.span)
        curve.blurExponent = look.blurExponent
        curve.dimExponent = look.dimExponent
        let progress = curve.progress(at: angle)
        let corners = LidFoldGeometry.corners(screenWidth: width, screenHeight: height, startAngle: look.startAngle,
                                              angle: angle, look: look)
        // Deep into the close the picture is nearly edge-on and its hinge rows stretch across the glass; frost
        // them too so nothing streaks.
        let separation = min(look.depth * max(look.startAngle - angle, 0), LidFoldGeometry.maximumSeparation)
        return LidFoldFrame(corners: corners,
                            blurStrength: curve.blurStrength(progress: progress),
                            dimStrength: curve.dimStrength(progress: progress),
                            blurFloor: LidFoldCurve.smoothstep((separation - 45) / 35),
                            maxDim: look.dimming, maxBlurRadius: look.blurRadius,
                            dimReach: look.dimReach, dimHingeFloor: look.dimHingeFloor,
                            topEdge: corners[2].y)
    }
}
