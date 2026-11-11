import XCTest
@testable import AnodeApp

/// A privacy approval that macOS keeps against an older build is cleared and asked for again once for each build,
/// never on every check, and never when the build cannot be identified.
final class ApprovalRepairTests: XCTestCase {

    private func defaults() throws -> UserDefaults {
        let (d, name) = try TestDefaults.make(owner: "ApprovalRepair", test: self.name)
        addTeardownBlock { TestDefaults.destroy(d, name) }
        return d
    }

    func testRepairsTheFirstTimeABuildIsSeenAndNotAgain() {
        XCTAssertTrue(ApprovalRepair.shouldRepair(lastRepairedFor: nil, current: "aa"))
        XCTAssertFalse(ApprovalRepair.shouldRepair(lastRepairedFor: "aa", current: "aa"))
        XCTAssertTrue(ApprovalRepair.shouldRepair(lastRepairedFor: "aa", current: "bb"), "an update is a new build")
    }

    func testNeverRepairsABuildItCannotIdentify() {
        XCTAssertFalse(ApprovalRepair.shouldRepair(lastRepairedFor: nil, current: nil))
        XCTAssertFalse(ApprovalRepair.shouldRepair(lastRepairedFor: nil, current: ""))
    }

    func testClearsAndAsksOncePerBuildEvenWhenCheckedEveryTwoSeconds() throws {
        let d = try defaults()
        var cleared = 0, asked = 0
        func check(_ build: String?) {
            ApprovalRepair.repairOncePerBuild(.accessibility, defaults: d, current: build,
                                              clear: { _, then in cleared += 1; then() }, ask: { asked += 1 })
        }
        for _ in 0..<5 { check("build1") }
        XCTAssertEqual(cleared, 1); XCTAssertEqual(asked, 1, "the retry timer must not nag")
        check("build2")
        XCTAssertEqual(cleared, 2); XCTAssertEqual(asked, 2, "after an update it is put right again")
        check(nil)
        XCTAssertEqual(cleared, 2)
    }

    func testEachServiceKeepsItsOwnRecord() throws {
        let d = try defaults()
        var services: [ApprovalRepair.Service] = []
        for s in [ApprovalRepair.Service.accessibility, .screenRecording, .accessibility] {
            ApprovalRepair.repairOncePerBuild(s, defaults: d, current: "x", clear: { s, then in services.append(s); then() }, ask: {})
        }
        XCTAssertEqual(services, [.accessibility, .screenRecording])
    }

    func testTheRunningBuildCanBeIdentified() {
        let id = CodeIdentity.current()
        XCTAssertNotNil(id)
        XCTAssertTrue(["ad-hoc", "certificate", "unsigned"].contains(id?.kind ?? ""))
    }

    func testTheServiceNamesAreTheOnesTccutilTakes() {
        XCTAssertEqual(ApprovalRepair.Service.accessibility.rawValue, "Accessibility")
        XCTAssertEqual(ApprovalRepair.Service.screenRecording.rawValue, "ScreenCapture")
    }
}
