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
    /// Each test has its own record of the owner's brightness, so a test that ends dimmed leaves nothing for the next.
    private let own = OwnBrightness()

    override func setUpWithError() throws { (defaults, suite) = try TestDefaults.make(owner: "LidDimmer", test: name) }
    override func tearDownWithError() throws { TestDefaults.destroy(defaults, suite) }
    private func make(_ ownBrightness: OwnBrightness? = nil) -> LidDimmer {
        LidDimmer(lid: lid, backlight: panel, defaults: defaults, ownBrightness: ownBrightness ?? own)
    }

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
        // The app dies here. A new one starts, with nothing remembered in memory, and releases first thing.
        let relaunched = make(OwnBrightness())
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

    // ── The owner's brightness, shared with the other feature that lowers it ─

    func testTwoOwnersShareOneRememberedBrightness() {
        // The lid dimmer remembers 0.8, then the ceiling remembers 0.5 (the screen was already lower by then).
        let record = OwnBrightness()
        record.remember(0.8, for: "lid")
        record.remember(0.5, for: "ceiling")
        XCTAssertNil(record.forget("lid"), "the ceiling still wants the screen lowered")
        XCTAssertEqual(record.forget("ceiling"), 0.8, "the last to leave gets the earliest value")

        // Whichever leaves first, the other gets it.
        record.remember(0.7, for: "ceiling")
        record.remember(0.2, for: "lid")
        XCTAssertNil(record.forget("ceiling"))
        XCTAssertEqual(record.forget("lid"), 0.7)

        // With nobody left nothing is remembered, so the next one starts afresh.
        record.remember(0.3, for: "lid")
        XCTAssertEqual(record.forget("lid"), 0.3)
        XCTAssertNil(record.forget("lid"), "forgotten already")
    }

    func testAnOwnerThatWasNeverNotedForgetsNothingAndChangesNothing() {
        let record = OwnBrightness()
        XCTAssertNil(record.forget("lid"))
        record.remember(0.8, for: "ceiling")
        XCTAssertNil(record.forget("lid"), "not an owner: the ceiling's value is not the lid's to take")
        XCTAssertEqual(record.forget("ceiling"), 0.8)
        // Noting the same owner twice is still one owner.
        record.remember(0.6, for: "lid")
        record.remember(0.4, for: "lid")
        XCTAssertEqual(record.forget("lid"), 0.6)
    }

    func testTheLidIsTheLastToLeaveAndPutsBackTheOwnersOwnBrightness() {
        let d = make()
        own.remember(0.8, for: "ultra")
        panel.value = 0.5                      // the ceiling already lowered it
        d.poll()                               // open: reads 0.5
        lid.closed = true; d.poll()
        XCTAssertEqual(panel.value, 0)
        XCTAssertNil(own.forget("ultra"), "the mode ends while the lid still holds the screen down")
        lid.closed = false; d.poll()
        XCTAssertEqual(panel.value, 0.8, accuracy: 0.001, "the owner's brightness, not the ceiling the lid saw")
        XCTAssertFalse(d.isDimmed)
    }

    func testTheLidOpensToTheLevelItSawWhileAnotherFeatureStillHoldsTheScreenDown() {
        let d = make()
        own.remember(0.8, for: "ultra")
        panel.value = 0.5
        d.poll()
        lid.closed = true; d.poll()
        lid.closed = false; d.poll()
        XCTAssertEqual(panel.value, 0.5, accuracy: 0.001, "neither black nor the owner's 0.8: the mode is still on")
        XCTAssertFalse(d.isDimmed)
        XCTAssertEqual(own.forget("ultra"), 0.8, "the mode, now the last, gets the owner's brightness")
    }

    func testAFailedRestoreWhileSharedIsRetriedToTheSameBrightness() {
        // The lid is the last to leave: the retry still goes to the owner's 0.8.
        own.remember(0.8, for: "ultra")
        panel.value = 0.5
        let d = make()
        d.poll(); lid.closed = true; d.poll()
        XCTAssertNil(own.forget("ultra"))
        lid.closed = false; panel.refuse = true; d.poll()
        XCTAssertTrue(d.isDimmed, "kept, not forgotten")
        panel.refuse = false; d.poll()
        XCTAssertEqual(panel.value, 0.8, accuracy: 0.001)
        XCTAssertFalse(d.isDimmed)
    }

    func testAFailedRestoreWhileAnotherFeatureHoldsTheScreenKeepsTheirValue() {
        own.remember(0.8, for: "ultra")
        panel.value = 0.5
        let d = make()
        d.poll(); lid.closed = true; d.poll()
        lid.closed = false; panel.refuse = true; d.poll()
        panel.refuse = false; d.poll()
        XCTAssertEqual(panel.value, 0.5, accuracy: 0.001)
        XCTAssertEqual(own.forget("ultra"), 0.8, "the failed attempt did not take the mode's value or its place")
    }

    func testAPanelThatRefusesToDimLeavesNoOwnerBehind() {
        let d = make()
        d.poll(); lid.closed = true; panel.refuse = true; d.poll()
        XCTAssertFalse(d.isDimmed)
        // If the lid were still noted, this would be 0.6 left over from the refused dimming, or nil.
        own.remember(0.3, for: "ultra")
        XCTAssertEqual(own.forget("ultra"), 0.3)
    }
}
