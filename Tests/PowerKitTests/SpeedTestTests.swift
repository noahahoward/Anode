import XCTest
@testable import PowerKit

/// The arithmetic and the ramp rules. Deliberately NO network: a test that needs
/// the internet fails on a plane, in CI, and in a hotel, and then gets deleted.
/// The transfer itself is exercised by `betterstats --speedtest`, which a person
/// runs on purpose.
final class SpeedTestTests: XCTestCase {

    /// Base 10, because that is the unit an ISP sells in and the whole point is
    /// comparing against what you pay for. Bytes elsewhere in this app are base
    /// 2; this is the one deliberate exception.
    func testMbpsIsBaseTenBitsPerSecond() {
        // 1 MB in 1 s = 8 Mbit/s exactly.
        XCTAssertEqual(SpeedTest.mbps(bytes: 1_000_000, seconds: 1)!, 8.0, accuracy: 1e-9)
        // 25 MB in 2 s = 100 Mbit/s.
        XCTAssertEqual(SpeedTest.mbps(bytes: 25_000_000, seconds: 2)!, 100.0, accuracy: 1e-9)
        // A base-2 megabyte would give 8.389; if this ever passes, the unit slipped.
        XCTAssertNotEqual(SpeedTest.mbps(bytes: 1_048_576, seconds: 1)!, 8.0, accuracy: 0.01)
    }

    /// Nothing divides by zero and nothing reports a rate for no bytes. A speed
    /// test that prints 0 Mbps has claimed a measurement it did not make.
    func testDegenerateInputProducesNoRate() {
        XCTAssertNil(SpeedTest.mbps(bytes: 0, seconds: 1))
        XCTAssertNil(SpeedTest.mbps(bytes: 1_000_000, seconds: 0))
        XCTAssertNil(SpeedTest.mbps(bytes: -5, seconds: 1))
    }

    /// A transfer that finishes before TCP leaves slow start measures the ramp,
    /// not the link, so the ladder steps up.
    func testAFastPhaseRampsToALargerSize() {
        XCTAssertEqual(SpeedTest.nextSize(after: 1_000_000, seconds: 0.3,
                                          in: SpeedTest.downSizes), 10_000_000)
        XCTAssertEqual(SpeedTest.nextSize(after: 10_000_000, seconds: 1.1,
                                          in: SpeedTest.downSizes), 25_000_000)
    }

    /// Once a phase has run long enough to be meaningful, stop — more bytes
    /// would spend the user's data for no extra confidence.
    func testAMeaningfulPhaseStopsTheRamp() {
        XCTAssertNil(SpeedTest.nextSize(after: 1_000_000, seconds: 2.0,
                                        in: SpeedTest.downSizes))
        XCTAssertNil(SpeedTest.nextSize(after: 1_000_000, seconds: 9,
                                        in: SpeedTest.downSizes))
    }

    /// The ladder is finite: a link so slow that even the largest size is quick
    /// must not loop forever asking for a bigger one.
    func testTheRampTerminatesAtTheTopOfTheLadder() {
        XCTAssertNil(SpeedTest.nextSize(after: 25_000_000, seconds: 0.1,
                                        in: SpeedTest.downSizes))
        XCTAssertNil(SpeedTest.nextSize(after: 10_000_000, seconds: 0.1,
                                        in: SpeedTest.upSizes))
        // A size that is not on the ladder at all cannot select a successor.
        XCTAssertNil(SpeedTest.nextSize(after: 7, seconds: 0.1, in: SpeedTest.downSizes))
    }

    /// The upload ladder is smaller than the download one on purpose: upload is
    /// usually the slower direction, so the same byte count costs more time, and
    /// this is data the user is sending from their own connection.
    func testUploadSpendsLessOfTheUsersData() {
        XCTAssertLessThan(SpeedTest.upSizes.max()!, SpeedTest.downSizes.max()!)
    }

    /// The endpoint is nameable before anything is sent — the UI has to be able
    /// to say who is being contacted.
    func testTheEndpointNamesItself() {
        XCTAssertEqual(SpeedTest.Endpoint.cloudflare.host, "speed.cloudflare.com")
        XCTAssertTrue(SpeedTest.Endpoint.cloudflare.downURL(1000).absoluteString
            .hasPrefix("https://"), "never plaintext")
        XCTAssertTrue(SpeedTest.Endpoint.cloudflare.upURL.absoluteString.hasPrefix("https://"))
    }
}
