import XCTest
@testable import PowerKit

/// The layout data for every Mac family: counts, identity, and the heat pipe's
/// left-right symmetry (a one-sided pipe drawn over a symmetric board would be
/// a wrong picture).
final class HardwareLayoutTests: XCTestCase {

    private let families: [MacFamily] = [
        .macBookPro14ProMax, .macBookPro16ProMax, .macBookPro14Base,
        .macBookNeo, .macMiniM4, .generic
    ]

    private func fanCount(_ layout: HardwareLayout) -> Int {
        layout.components.filter {
            if case .fan = $0.kind { return true }
            return false
        }.count
    }

    private func hasKind(_ layout: HardwareLayout, _ kind: HardwareComponentKind) -> Bool {
        layout.components.contains { $0.kind == kind }
    }

    func testEveryFamilyReturnsItsOwnLayout() {
        for family in families {
            let layout = HardwareLayout.layout(for: family)
            XCTAssertEqual(layout.family, family)
            XCTAssertFalse(layout.title.isEmpty, "\(family)")
            XCTAssertGreaterThan(layout.size.w, 0, "\(family)")
            XCTAssertGreaterThan(layout.size.h, 0, "\(family)")
            XCTAssertFalse(layout.components.isEmpty, "\(family)")
        }
    }

    func testFanCountsPerFamily() {
        XCTAssertEqual(fanCount(HardwareLayout.layout(for: .macBookPro14ProMax)), 2)
        XCTAssertEqual(fanCount(HardwareLayout.layout(for: .macBookPro16ProMax)), 2)
        XCTAssertEqual(fanCount(HardwareLayout.layout(for: .macBookPro14Base)), 1)
        XCTAssertEqual(fanCount(HardwareLayout.layout(for: .macBookNeo)), 0)
        XCTAssertEqual(fanCount(HardwareLayout.layout(for: .macMiniM4)), 1)
        XCTAssertEqual(fanCount(HardwareLayout.layout(for: .generic)), 2)
    }

    func testFanIndexesRunFromZeroWithoutGaps() {
        for family in families {
            var indexes: [Int] = []
            for c in HardwareLayout.layout(for: family).components {
                if case .fan(let index) = c.kind { indexes.append(index) }
            }
            XCTAssertEqual(indexes.sorted(), Array(0..<indexes.count), "\(family)")
        }
    }

    func testNeoHasNoFan() {
        let neo = HardwareLayout.layout(for: .macBookNeo)
        for c in neo.components {
            if case .fan = c.kind { XCTFail("the Neo is fanless but has \(c.id)") }
        }
    }

    func testMiniHasNoBatteryOrDisplay() {
        let mini = HardwareLayout.layout(for: .macMiniM4)
        XCTAssertFalse(hasKind(mini, .battery))
        XCTAssertFalse(hasKind(mini, .display))
        XCTAssertTrue(hasKind(mini, .psu))
    }

    func testLaptopsHaveABatteryAndADisplay() {
        for family in [MacFamily.macBookPro14ProMax, .macBookPro16ProMax,
                       .macBookPro14Base, .macBookNeo] {
            let layout = HardwareLayout.layout(for: family)
            XCTAssertTrue(hasKind(layout, .battery), "\(family)")
            XCTAssertTrue(hasKind(layout, .display), "\(family)")
        }
    }

    func testEveryComponentIDIsUnique() {
        for family in families {
            let ids = HardwareLayout.layout(for: family).components.map { $0.id }
            XCTAssertEqual(Set(ids).count, ids.count, "\(family): \(ids)")
        }
    }

    func testOnlyTheProMaxLayoutsUseThePhoto() {
        for family in [MacFamily.macBookPro14ProMax, .macBookPro16ProMax] {
            let layout = HardwareLayout.layout(for: family)
            XCTAssertEqual(layout.photoResource, "macbook-pro-teardown")
            let frame = layout.photoFrame
            XCTAssertNotNil(frame)
            XCTAssertEqual(frame?.x ?? 0, 40, accuracy: 0.001)
            XCTAssertEqual(frame?.y ?? 0, 468, accuracy: 0.001)
            XCTAssertEqual(frame?.w ?? 0, 1020, accuracy: 0.001)
            XCTAssertEqual(frame?.h ?? 0, 1165.0 * 1020.0 / 1700.0, accuracy: 0.001)
            XCTAssertEqual(layout.size.w, 1100, accuracy: 0.001)
            XCTAssertEqual(layout.size.h, 1205, accuracy: 0.001)
        }
        for family in [MacFamily.macBookPro14Base, .macBookNeo, .macMiniM4, .generic] {
            let layout = HardwareLayout.layout(for: family)
            XCTAssertNil(layout.photoResource, "\(family)")
            XCTAssertNil(layout.photoFrame, "\(family)")
        }
    }

    func testPhotoFanIsASquareAboutItsCentre() {
        // r = 126 * (3415/2296) * (1700/3362) * (1020/1700)
        let r = 126.0 * (3415.0 / 2296.0) * (1700.0 / 3362.0) * (1020.0 / 1700.0)
        let layout = HardwareLayout.layout(for: .macBookPro14ProMax)
        for c in layout.components {
            guard case .fan = c.kind else { continue }
            XCTAssertEqual(c.points.count, 1, c.id)
            guard let centre = c.points.first, let rect = c.rect else {
                XCTFail("\(c.id) has no centre or rect")
                continue
            }
            XCTAssertEqual(rect.w, 2 * r, accuracy: 0.01, c.id)
            XCTAssertEqual(rect.h, 2 * r, accuracy: 0.01, c.id)
            XCTAssertEqual(rect.x + rect.w / 2, centre.x, accuracy: 0.001, c.id)
            XCTAssertEqual(rect.y + rect.h / 2, centre.y, accuracy: 0.001, c.id)
        }
    }

    func testPhotoFansMatchTheWarpedMockupPositions() {
        let layout = HardwareLayout.layout(for: .macBookPro14ProMax)
        let fans = layout.components.filter { if case .fan = $0.kind { return true } else { return false } }
        XCTAssertEqual(fans.count, 2)
        let expected = [(434.0, 488.0), (1845.0, 481.0)]
        for (i, e) in expected.enumerated() {
            let p = PhotoWarp.straightened.drawingPoint(photoX: e.0, photoY: e.1)
            XCTAssertEqual(fans[i].points.first?.x ?? 0, p.x, accuracy: 0.001)
            XCTAssertEqual(fans[i].points.first?.y ?? 0, p.y, accuracy: 0.001)
        }
        // Fan 1 is left of the centre line, fan 2 right of it.
        XCTAssertLessThan(fans[0].points[0].x, 550)
        XCTAssertGreaterThan(fans[1].points[0].x, 550)
    }

    /// Distance from a point to the nearest segment of a polyline.
    private func distance(from p: HWPoint, to line: [HWPoint]) -> Double {
        var best = Double.greatestFiniteMagnitude
        for i in 0..<(line.count - 1) {
            let a = line[i]
            let b = line[i + 1]
            let dx = b.x - a.x
            let dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            var t = len2 > 0 ? ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2 : 0
            t = max(0, min(1, t))
            let cx = a.x + t * dx
            let cy = a.y + t * dy
            best = min(best, ((p.x - cx) * (p.x - cx) + (p.y - cy) * (p.y - cy)).squareRoot())
        }
        return best
    }

    func testHeatPipePointsAreLeftRightSymmetric() {
        var checked = 0
        for family in families {
            let layout = HardwareLayout.layout(for: family)
            for c in layout.components where c.kind == .heatPipe && c.points.count > 1 {
                checked += 1
                let first = c.points[0]
                let last = c.points[c.points.count - 1]
                let centre = (first.x + last.x) / 2
                // The pipe is centred on the picture's centre line.
                XCTAssertEqual(centre, layout.size.w / 2, accuracy: 2, "\(family) pipe centre")
                for p in c.points {
                    let mirrored = HWPoint(x: 2 * centre - p.x, y: p.y)
                    XCTAssertLessThan(distance(from: mirrored, to: c.points), 2,
                                      "\(family): (\(p.x), \(p.y)) has no mirror image")
                }
            }
        }
        XCTAssertGreaterThan(checked, 0, "the photo layout's pipe has a path")
    }

    func testPhotoPipeRunsAcrossTheChassisAndCarriesBothPills() {
        let layout = HardwareLayout.layout(for: .macBookPro14ProMax)
        guard let pipe = layout.components.first(where: { $0.kind == .heatPipe }) else {
            XCTFail("no heat pipe")
            return
        }
        XCTAssertGreaterThan(pipe.points.count, 50)
        let cpu = pipe.anchors["cpu"]
        let gpu = pipe.anchors["gpu"]
        XCTAssertNotNil(cpu)
        XCTAssertNotNil(gpu)
        // The CPU pill is on the left half, the GPU pill on the right.
        XCTAssertLessThan(cpu?.x ?? 1000, 550)
        XCTAssertGreaterThan(gpu?.x ?? 0, 550)
        // Both pills sit on the pipe.
        if let cpu = cpu, let gpu = gpu {
            XCTAssertLessThan(distance(from: cpu, to: pipe.points), 2)
            XCTAssertLessThan(distance(from: gpu, to: pipe.points), 2)
        }
    }

    func testBatteryCellsCoverEverySixRolesOnProLayouts() {
        for family in [MacFamily.macBookPro14ProMax, .macBookPro14Base] {
            let layout = HardwareLayout.layout(for: family)
            guard let battery = layout.components.first(where: { $0.kind == .battery }) else {
                XCTFail("no battery for \(family)")
                continue
            }
            let roles = Set(battery.parts.flatMap { $0.roles })
            XCTAssertEqual(roles, ["charge", "temp", "state", "graph", "draw", "health"], "\(family)")
        }
    }

    func testEveryJumpHasALabel() {
        for family in families {
            for c in HardwareLayout.layout(for: family).components {
                XCTAssertEqual(c.jump != nil, c.jumpLabel != nil, "\(family) \(c.id)")
            }
        }
    }

    func testMiniDrawingUsesItsOwnViewBox() {
        let mini = HardwareLayout.layout(for: .macMiniM4)
        XCTAssertEqual(mini.size, HWRect(x: 130, y: 0, w: 840, h: 800))
    }
}
