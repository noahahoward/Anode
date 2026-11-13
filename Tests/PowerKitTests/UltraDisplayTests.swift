import XCTest
@testable import AnodeApp
@testable import PowerKit

/// The screen's refresh rate and the keyboard light, as Ultra Low Power Mode asks for them. The part that decides is
/// plain values in and an answer out; the calls into the system are not made here. The one test that reads the live
/// Mac is skipped unless `ANODE_ULTRA_LIVE=1`, and it only reads.
final class UltraDisplayTests: XCTestCase {

    /// A display mode with nothing behind it, so no screen is touched.
    private struct StubMode: DisplayModeValues {
        var width: Int
        var height: Int
        var pixelWidth: Int
        var pixelHeight: Int
        var refreshRate: Double
        var usable = true
        func isUsableForDesktopGUI() -> Bool { usable }
    }

    private func mode(_ width: Int, _ height: Int, _ pixelWidth: Int, _ pixelHeight: Int, _ rate: Double,
                      usable: Bool = true) -> StubMode {
        StubMode(width: width, height: height, pixelWidth: pixelWidth, pixelHeight: pixelHeight, refreshRate: rate,
                 usable: usable)
    }

    func testModeListMapsToDisplayModeInfo() {
        let modes: [DisplayModeValues] = [
            mode(1512, 982, 3024, 1964, 120),
            mode(1512, 982, 3024, 1964, 60),
            mode(1728, 1117, 3456, 2234, 0),
            mode(1470, 956, 2940, 1912, 60, usable: false),
        ]
        XCTAssertEqual(LiveDisplayRate.info(from: modes), [
            DisplayModeInfo(index: 0, width: 1512, height: 982, pixelWidth: 3024, pixelHeight: 1964, rate: 120, usable: true),
            DisplayModeInfo(index: 1, width: 1512, height: 982, pixelWidth: 3024, pixelHeight: 1964, rate: 60, usable: true),
            DisplayModeInfo(index: 2, width: 1728, height: 1117, pixelWidth: 3456, pixelHeight: 2234, rate: 0, usable: true),
            DisplayModeInfo(index: 3, width: 1470, height: 956, pixelWidth: 2940, pixelHeight: 1912, rate: 60, usable: false),
        ])
    }

    func testTheModeAskedForIsTheLowestRateAtTheCurrentResolutionAndIsFoundBackInTheList() {
        let current = mode(1512, 982, 3024, 1964, 120)
        let modes: [DisplayModeValues] = [
            mode(1728, 1117, 3456, 2234, 30),            // lower, but another picture
            current,
            mode(1512, 982, 3024, 1964, 60),
            mode(1512, 982, 3024, 1964, 48),
        ]
        // Index 3 of the list: the picker's answer is read back as a place in the list the system gave, not as a copy.
        XCTAssertEqual(LiveDisplayRate.lowerIndex(in: modes, current: current), 3)
    }

    func testAScreenWithOneRateHasNothingToLower() {
        let current = mode(1512, 982, 3024, 1964, 60)
        let modes: [DisplayModeValues] = [current, mode(1728, 1117, 3456, 2234, 30)]
        XCTAssertNil(LiveDisplayRate.lowerIndex(in: modes, current: current))
        XCTAssertNil(LiveDisplayRate.lowerIndex(in: [], current: current))
    }

    func testAModeTheDisplayWillNotTakeIsNeverAskedFor() {
        let current = mode(1512, 982, 3024, 1964, 120)
        let modes: [DisplayModeValues] = [current, mode(1512, 982, 3024, 1964, 24, usable: false)]
        XCTAssertNil(LiveDisplayRate.lowerIndex(in: modes, current: current))
    }

    // ── The real Mac, read only ─────────────────────────────────────────────

    /// Asks the built-in display whether it has a lower rate and the keyboard for its level. It sets nothing: the two
    /// that change the screen and the light are not called. Skipped unless `ANODE_ULTRA_LIVE=1`.
    func testLiveReadOnlySmoke() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ANODE_ULTRA_LIVE"] == "1",
                          "set ANODE_ULTRA_LIVE=1 to read the real display and keyboard light (read only)")
        let rate = LiveDisplayRate()
        print("ULTRA LIVE: built-in display can be lowered: \(rate.canLower)")
        let keyboard = LiveKeyboardBacklight()
        let level = keyboard.level()
        print("ULTRA LIVE: keyboard light level: \(level.map { String(format: "%.3f", $0) } ?? "none")")
        if let level { XCTAssertTrue((0...1).contains(level)) }
    }
}
