import XCTest
@testable import PowerKit

/// PPMC carrying the GPU's watts on some chips, and the ledger not counting them twice.
final class RailOverlapTests: XCTestCase {

    private typealias M = PowerMonitor

    /// The MacBook Neo's measured medians: 7.4 W + 3.8 W against a 10.6 W whole
    /// machine that the gas gauge confirmed. Disjoint rails cannot do that.
    func testTheNeoRailsOverlap() {
        XCTAssertTrue(M.railsOverlap(ppmc: 7.4, gpu: 3.8, total: 10.6, samples: 15, window: 15))
    }

    /// The M5 Pro's rails are disjoint and leave room for everything else.
    func testDisjointRailsDoNotLatch() {
        XCTAssertFalse(M.railsOverlap(ppmc: 4.0, gpu: 3.0, total: 12.0, samples: 15, window: 15))
        XCTAssertFalse(M.railsOverlap(ppmc: 6.0, gpu: 4.1, total: 10.0, samples: 15, window: 15),
                       "within rail noise is not proof")
    }

    func testAPartWindowCannotLatch() {
        XCTAssertFalse(M.railsOverlap(ppmc: 7.4, gpu: 3.8, total: 10.6, samples: 4, window: 15))
    }

    func testTheCPUShareSubtractsTheGPUOnlyWhenTheyOverlap() {
        XCTAssertEqual(M.cpuOnlyRail(ppmc: 7.4, gpu: 3.8, includesGPU: true), 3.6, accuracy: 1e-9)
        XCTAssertEqual(M.cpuOnlyRail(ppmc: 7.4, gpu: 3.8, includesGPU: false), 7.4)
        XCTAssertEqual(M.cpuOnlyRail(ppmc: 1.0, gpu: 3.8, includesGPU: true), 0,
                       "never a negative CPU")
        XCTAssertEqual(M.cpuOnlyRail(ppmc: 7.4, gpu: nil, includesGPU: true), 7.4,
                       "no GPU reading, nothing to subtract")
    }
}
