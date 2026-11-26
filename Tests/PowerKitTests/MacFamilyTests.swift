import XCTest
@testable import PowerKit

/// The family is decided from traits, never from a model identifier, so a new
/// model with the same hardware resolves the same way and an unfamiliar one is
/// `.generic` rather than a guess.
final class MacFamilyTests: XCTestCase {

    private func traits(model: String = "Mac17,9",
                        chip: String,
                        fans: FanPresence.State,
                        battery: Bool = true,
                        width: Int? = 3024) -> MacTraits {
        MacTraits(model: model, chip: chip, fans: fans,
                  hasBattery: battery, builtInDisplayPixelWidth: width)
    }

    func testThisMacIsFourteenInchProMax() {
        let t = traits(chip: "Apple M5 Pro", fans: .fans(2))
        XCTAssertEqual(MacFamilyResolver.resolve(t), .macBookPro14ProMax)
    }

    func testProChipWithOneFanIsGeneric() {
        let t = traits(chip: "Apple M5 Pro", fans: .fans(1))
        XCTAssertEqual(MacFamilyResolver.resolve(t), .generic)
    }

    func testUnknownFansAreGeneric() {
        let t = traits(chip: "Apple M5 Pro", fans: .unknown)
        XCTAssertEqual(MacFamilyResolver.resolve(t), .generic)
    }

    func testA18FanlessLaptopIsNeo() {
        let t = traits(model: "Mac17,5", chip: "Apple A18 Pro", fans: .fanless, width: 2408)
        XCTAssertEqual(MacFamilyResolver.resolve(t), .macBookNeo)
    }

    func testA18WithFansIsGeneric() {
        let t = traits(model: "Mac17,5", chip: "Apple A18 Pro", fans: .fans(1))
        XCTAssertEqual(MacFamilyResolver.resolve(t), .generic)
    }

    func testBaseChipWithOneFanAt3024IsBase14() {
        let t = traits(chip: "Apple M4", fans: .fans(1))
        XCTAssertEqual(MacFamilyResolver.resolve(t), .macBookPro14Base)
    }

    func testMaxWithTwoFansAt3456IsSixteenInchProMax() {
        let t = traits(chip: "Apple M4 Max", fans: .fans(2), width: 3456)
        XCTAssertEqual(MacFamilyResolver.resolve(t), .macBookPro16ProMax)
    }

    func testNoBatteryNoDisplayOneFanM4IsMini() {
        let t = traits(model: "Mac16,10", chip: "Apple M4", fans: .fans(1),
                       battery: false, width: nil)
        XCTAssertEqual(MacFamilyResolver.resolve(t), .macMiniM4)
    }

    func testUnfamiliarModelAndChipIsGeneric() {
        let t = traits(model: "Mac99,1", chip: "Apple M9", fans: .fans(1),
                       battery: false, width: nil)
        XCTAssertEqual(MacFamilyResolver.resolve(t), .generic)
    }
}
