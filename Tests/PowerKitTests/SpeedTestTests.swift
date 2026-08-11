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

// ─────────────────────────────────────────────────────────────────────────────

/// Whether to ask before spending someone's data.
///
/// The only part of this feature that can be got wrong expensively: a monitor
/// that quietly moves 47 MB over a phone plan has done real harm with one click.
final class SpeedTestGateTests: XCTestCase {

    private let host = "speed.cloudflare.com"

    /// Every rung of both ladders. The earlier sizes are not replaced by the
    /// later ones — they are spent climbing to them.
    func testTheDisclosedSizeIsEveryRungOfBothLadders() {
        XCTAssertEqual(SpeedTestGate.worstCaseBytes,
                       SpeedTest.downSizes.reduce(0, +) + SpeedTest.upSizes.reduce(0, +))
        // 1 + 10 + 25 down, 1 + 10 up, on the ladders as they stand.
        XCTAssertEqual(SpeedTestGate.worstCaseBytes, 47_000_000)
    }

    /// Said once, properly, rather than every time — a dialog shown on every run
    /// is one nobody reads.
    func testTheFirstRunExplainsItselfAndLaterOnesDoNot() {
        guard case .ask(let text) = SpeedTestGate.decide(hasAgreedBefore: false,
                                                         isExpensive: false,
                                                         isConstrained: false,
                                                         host: host) else {
            return XCTFail("the first run said nothing before sending data")
        }
        XCTAssertTrue(text.contains(host), "the disclosure does not name who is contacted")
        XCTAssertTrue(text.contains("47 MB"), "the disclosure does not say what it costs")
        XCTAssertTrue(text.localizedCaseInsensitiveContains("IP address"),
                      "the disclosure does not mention what the far end learns")

        XCTAssertEqual(SpeedTestGate.decide(hasAgreedBefore: true, isExpensive: false,
                                            isConstrained: false, host: host), .run)
    }

    /// A metered path asks EVERY time, agreed before or not. The cost there is
    /// recurring rather than a one-off explanation.
    func testAMeteredPathAsksEveryTime() {
        for constrained in [true, false] {
            for expensive in [true, false] where expensive || constrained {
                guard case .ask(let text) = SpeedTestGate.decide(hasAgreedBefore: true,
                                                                 isExpensive: expensive,
                                                                 isConstrained: constrained,
                                                                 host: host) else {
                    return XCTFail("ran a 47 MB transfer on a metered path without asking")
                }
                XCTAssertTrue(text.contains("47 MB"))
            }
        }
    }

    /// Low Data Mode is the user having already said, at the OS level, that they
    /// want less traffic here. The wording should show we heard that rather than
    /// guessing at cellular.
    func testLowDataModeIsNamedForWhatItIs() {
        guard case .ask(let text) = SpeedTestGate.decide(hasAgreedBefore: true,
                                                         isExpensive: false,
                                                         isConstrained: true,
                                                         host: host) else {
            return XCTFail("Low Data Mode did not ask")
        }
        XCTAssertTrue(text.contains("Low Data Mode"), text)
    }

    func testAnOrdinaryConnectionThatHasAgreedJustRuns() {
        XCTAssertEqual(SpeedTestGate.decide(hasAgreedBefore: true, isExpensive: false,
                                            isConstrained: false, host: host), .run)
    }
}
