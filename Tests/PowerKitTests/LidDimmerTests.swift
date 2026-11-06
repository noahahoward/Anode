import XCTest
@testable import PowerKit

/// The panel goes dark when the lid shuts and comes back exactly as it was; no sequence leaves it black.
final class LidDimmerTests: XCTestCase {

    final class FakeLidState: LidStateReader {
        var closed: Bool? = false
        func isClosed() -> Bool? { closed }
    }
    final class FakeBacklight: BacklightControl {
        var value: Float = 0.6
        var refuse = false
        var sets: [Float] = []
        func brightness() -> Float? { value }
        func setBrightness(_ v: Float) -> Bool { if refuse { return false }; value = v; sets.append(v); return true }
    }

    private var suite: String!
    private var defaults: UserDefaults!
    private let lid = FakeLidState()
    private let panel = FakeBacklight()

    override func setUpWithError() throws { (defaults, suite) = try TestDefaults.make(owner: "LidDimmer", test: name) }
    override func tearDownWithError() throws { TestDefaults.destroy(defaults, suite) }
    private func make() -> LidDimmer { LidDimmer(lid: lid, backlight: panel, defaults: defaults) }

    func testClosingTheLidDarkensAndOpeningRestoresTheOldBrightness() {
        let d = make()
        d.poll()                              // open: reads 0.6
        lid.closed = true; d.poll()
        XCTAssertEqual(panel.value, 0)
        XCTAssertTrue(d.isDimmed)
        lid.closed = false; d.poll()
        XCTAssertEqual(panel.value, 0.6, accuracy: 0.001)
        XCTAssertFalse(d.isDimmed)
    }

    func testTheBrightnessRestoredIsTheOneFromBeforeTheLidShut() {
        let d = make()
        d.poll()
        panel.value = 0.35                    // changed in System Settings; picked up within a few polls
        for _ in 0..<LidDimmer.refreshEvery { d.poll() }
        lid.closed = true; d.poll()
        lid.closed = false; d.poll()
        XCTAssertEqual(panel.value, 0.35, accuracy: 0.001)
    }

    func testStoppingWhileDimmedPutsTheBrightnessBack() {
        let d = make()
        d.poll(); lid.closed = true; d.poll()
        XCTAssertTrue(d.release())
        XCTAssertEqual(panel.value, 0.6, accuracy: 0.001)
        XCTAssertFalse(d.isDimmed)
    }

    func testACrashWhileDimmedIsUndoneByTheNextLaunch() {
        let d = make()
        d.poll(); lid.closed = true; d.poll()
        XCTAssertEqual(panel.value, 0)
        // The app dies here. A new one starts and releases first thing.
        let relaunched = make()
        XCTAssertTrue(relaunched.isDimmed)
        relaunched.release()
        XCTAssertEqual(panel.value, 0.6, accuracy: 0.001)
    }

    func testAFailedRestoreIsRetriedUntilItWorks() {
        let d = make()
        d.poll(); lid.closed = true; d.poll()
        lid.closed = false; panel.refuse = true; d.poll()
        XCTAssertTrue(d.isDimmed, "kept, not forgotten")
        panel.refuse = false; d.poll()
        XCTAssertEqual(panel.value, 0.6, accuracy: 0.001)
        XCTAssertFalse(d.isDimmed)
    }

    func testAPanelThatRefusesToDimIsNotMarkedDimmed() {
        let d = make()
        d.poll(); lid.closed = true; panel.refuse = true; d.poll()
        XCTAssertFalse(d.isDimmed)
        panel.refuse = false; d.poll()
        XCTAssertTrue(d.isDimmed, "tried again on the next poll")
    }

    func testAPanelAlreadyDarkIsLeftAlone() {
        panel.value = 0
        let d = make()
        d.poll(); lid.closed = true; d.poll()
        XCTAssertFalse(d.isDimmed)
        XCTAssertTrue(panel.sets.isEmpty)
    }

    func testAMacWithNoLidIsNeverTouched() {
        lid.closed = nil
        let d = make()
        d.poll(); d.poll()
        XCTAssertTrue(panel.sets.isEmpty)
        XCTAssertFalse(d.isDimmed)
    }

    func testReleaseWithNothingDimmedDoesNothing() {
        let d = make()
        XCTAssertTrue(d.release())
        XCTAssertTrue(panel.sets.isEmpty)
    }
}
