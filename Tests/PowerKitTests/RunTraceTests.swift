import XCTest
@testable import AnodeApp

/// The launch check that tells a run that quit properly from one that was killed.
final class RunTraceTests: XCTestCase {

    func testNoMarkerMeansTheLastRunQuitProperly() {
        XCTAssertNil(RunTrace.runThatEndedBadly(marker: nil, current: 10, isAlive: { _ in false }))
    }

    func testAMarkerWhoseProcessIsGoneMeansItDied() {
        XCTAssertEqual(RunTrace.runThatEndedBadly(marker: "4242\n", current: 10, isAlive: { _ in false }), 4242)
    }

    func testAMarkerWhoseProcessIsStillRunningIsAnotherCopyNotACrash() {
        XCTAssertNil(RunTrace.runThatEndedBadly(marker: "4242", current: 10, isAlive: { $0 == 4242 }))
    }

    func testItsOwnMarkerAndGarbageAreIgnored() {
        XCTAssertNil(RunTrace.runThatEndedBadly(marker: "10", current: 10, isAlive: { _ in false }))
        XCTAssertNil(RunTrace.runThatEndedBadly(marker: "not a pid", current: 10, isAlive: { _ in false }))
        XCTAssertNil(RunTrace.runThatEndedBadly(marker: "", current: 10, isAlive: { _ in false }))
    }
}

final class QuitCauseTests: XCTestCase {
    func testFourCharacterCodes() {
        XCTAssertEqual(RunTrace.fourCharacterCode(0x61657674), "aevt")
        XCTAssertEqual(RunTrace.fourCharacterCode(0x71756974), "quit")
        XCTAssertEqual(RunTrace.fourCharacterCode(0x73706964), "spid")
    }

    func testNothingInProgressIsSaidPlainly() {
        XCTAssertTrue(RunTrace.quitCause().contains("no event in progress") || RunTrace.quitCause().contains("event"))
    }

    func testCallersNamesFramesAndDoesNotCrash() {
        XCTAssertFalse(RunTrace.callers().joined().isEmpty)
    }
}
