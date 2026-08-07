import XCTest
@testable import PowerKit

/// Fan policy is the last thing standing between a slider and a hardware write,
/// so it is tested for what it REFUSES at least as hard as for what it allows.
/// A fan pinned wrong is a thermal problem the user cannot hear coming, because
/// a quiet fan is exactly what "everything is fine" sounds like.
final class FanPolicyTests: XCTestCase {

    /// The real limits this machine reports.
    private let real = FanPolicy.Limits(minRPM: 2317, maxRPM: 7826)

    func testInRangeValuePassesThrough() {
        XCTAssertEqual(try? FanPolicy.resolve(rpm: 4000, limits: real).get(), 4000)
    }

    /// A slider dragged to its end means "as fast as this fan goes", not an
    /// error. Clamping is the right behaviour for a bounded control.
    func testOutOfRangeClampsToTheHardwareLimits() {
        XCTAssertEqual(try? FanPolicy.resolve(rpm: 99999, limits: real).get(), 7826)
        XCTAssertEqual(try? FanPolicy.resolve(rpm: 10, limits: real).get(), 2317)
    }

    /// Zero must NOT be honoured as "off". The floor is the fan's own reported
    /// minimum, and a request below it becomes that minimum rather than a stop.
    func testZeroBecomesTheMinimumRatherThanStoppingTheFan() {
        XCTAssertEqual(try? FanPolicy.resolve(rpm: 0, limits: real).get(), 2317)
        XCTAssertEqual(try? FanPolicy.resolve(rpm: -500, limits: real).get(), 2317)
    }

    func testNaNAndInfinityAreRejectedNotClamped() {
        XCTAssertEqual(FanPolicy.resolve(rpm: .nan, limits: real),
                       .failure(.notFinite))
        XCTAssertEqual(FanPolicy.resolve(rpm: .infinity, limits: real),
                       .failure(.notFinite))
    }

    func testUnknownFanIsRejected() {
        XCTAssertEqual(FanPolicy.resolve(rpm: 3000, limits: nil),
                       .failure(.unknownFan))
    }

    /// A fan whose reported max is at or below its min is a misread key, not a
    /// single-speed fan. Writing on the strength of that reading is indefensible,
    /// so it is refused rather than clamped to a nonsense value.
    func testImplausibleLimitsAreRejected() {
        for bad in [FanPolicy.Limits(minRPM: 5000, maxRPM: 5000),
                    FanPolicy.Limits(minRPM: 5000, maxRPM: 1000),
                    FanPolicy.Limits(minRPM: 0, maxRPM: 7000),
                    FanPolicy.Limits(minRPM: 100, maxRPM: 99999)] {
            XCTAssertEqual(FanPolicy.resolve(rpm: 3000, limits: bad),
                           .failure(.limitsImplausible),
                           "limits \(bad) must not authorise a write")
        }
    }

    func testFractionAndRPMRoundTrip() {
        for f in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let rpm = FanPolicy.rpm(fraction: f, limits: real)
            XCTAssertEqual(FanPolicy.fraction(rpm: rpm, limits: real), f, accuracy: 1e-9)
        }
    }

    /// Fraction 0 is the fan's MINIMUM, not a stopped fan — the slider has no
    /// "off" position by construction.
    func testFractionZeroIsMinimumNotStopped() {
        XCTAssertEqual(FanPolicy.rpm(fraction: 0, limits: real), 2317)
        XCTAssertEqual(FanPolicy.rpm(fraction: 1, limits: real), 7826)
    }

    func testFractionIsClampedForOutOfRangeInput() {
        XCTAssertEqual(FanPolicy.rpm(fraction: -3, limits: real), 2317)
        XCTAssertEqual(FanPolicy.rpm(fraction: 12, limits: real), 7826)
        XCTAssertEqual(FanPolicy.fraction(rpm: 0, limits: real), 0)
        XCTAssertEqual(FanPolicy.fraction(rpm: 999999, limits: real), 1)
    }

    /// Native is the shipped default, and its entire contract is that it writes
    /// nothing at all. If this ever changes, someone has to change this test on
    /// purpose.
    func testNativeIsTheDefaultMode() {
        XCTAssertEqual(FanMode.allCases.first, .native)
    }

    func testCommandsSurviveEncoding() throws {
        let cmds: [FanCommand] = [.setTarget(.init(index: 0, rpm: 3200)), .releaseAll]
        for c in cmds {
            let data = try JSONEncoder().encode(c)
            XCTAssertEqual(try JSONDecoder().decode(FanCommand.self, from: data), c)
        }
    }
}
