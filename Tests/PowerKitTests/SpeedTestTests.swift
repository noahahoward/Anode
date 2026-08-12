import XCTest
@testable import PowerKit

/// The arithmetic and the ramp rules. Deliberately NO network: a test that needs
/// the internet fails on a plane, in CI, and in a hotel, and then gets deleted.
/// The transfer itself is exercised by `anode --speedtest`, which a person
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

    // ── Measuring for a duration, not for a size ────────────────────────────
    //
    // The ladder these tests used to cover is gone, and it is worth recording
    // why rather than just deleting them. It climbed 1 → 10 → 25 MB and stopped
    // once a transfer took 2 s. On a 364 Mbps ethernet link 25 MB takes 0.55 s,
    // so it ran out of rungs while still inside TCP slow start and reported the
    // RAMP — about a third of the real figure, measured against other tools on
    // the same connection.

    /// The warmup is thrown away, so a phase has to be long enough to have
    /// something left after it.
    func testAPhaseOutlastsItsOwnWarmup() {
        XCTAssertGreaterThan(SpeedTest.downSeconds, SpeedTest.warmupSeconds * 2)
        XCTAssertGreaterThan(SpeedTest.upSeconds, SpeedTest.warmupSeconds * 2)
    }

    /// Upload runs for less time than download on purpose: it is usually the
    /// slower direction and it is the user's own data leaving their connection.
    func testUploadSpendsLessOfTheUsersData() {
        XCTAssertLessThan(SpeedTest.upSeconds, SpeedTest.downSeconds)
    }

    /// Several streams, because one connection to a distant CDN node is limited
    /// by round-trip time and the TCP window rather than by the link — which is
    /// exactly why a single-stream figure reads low on a fast line.
    func testItUsesMoreThanOneStream() {
        XCTAssertGreaterThan(SpeedTest.streams, 1)
    }

    /// Bytes follow from rate and time, and are bounded however fast the link is.
    func testTheEstimateIsRateTimesTimeAndIsCapped() {
        // 100 Mbps for 6 s = 75 MB.
        XCTAssertEqual(Double(SpeedTest.estimatedBytes(atMbps: 100, seconds: 6)),
                       75e6, accuracy: 1e5)
        XCTAssertEqual(SpeedTest.estimatedBytes(atMbps: 1_000_000, seconds: 6),
                       SpeedTest.maxBytesPerPhase)
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

    /// The cost scales with the line, because the test runs for a DURATION. A
    /// faster connection spends more, which is the honest consequence of not
    /// measuring the TCP ramp by accident.
    func testTheEstimatedCostRisesWithLineSpeed() {
        let slow = SpeedTestGate.estimatedBytes(atMbps: 10)
        let fast = SpeedTestGate.estimatedBytes(atMbps: 300)
        XCTAssertGreaterThan(fast, slow * 5)
        // 10 Mbps for 10 s of transfer is about 12.5 MB.
        XCTAssertEqual(Double(slow), 12.5e6, accuracy: 1e6)
        XCTAssertLessThanOrEqual(SpeedTestGate.estimatedBytes(atMbps: 100_000),
                                 SpeedTestGate.ceilingBytes,
                                 "a very fast link must still be bounded")
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
        XCTAssertTrue(text.contains("MB"), "the disclosure does not say what it costs")
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
                XCTAssertTrue(text.contains("MB"), text)
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

// ─────────────────────────────────────────────────────────────────────────────

/// The messages have to survive the trip to a label.
///
/// They did not: without `LocalizedError`, a bridged Swift error renders as
/// "PowerKit.SpeedTest.Failure error 0" — the case index — so every explanation
/// this type builds was discarded at the last step and the user was shown the
/// one message nobody wrote.
final class SpeedTestFailureTests: XCTestCase {

    func testAFailureExplainsItselfRatherThanPrintingItsCaseNumber() {
        let failure = SpeedTest.Failure.unreachable("the server answered HTTP 429")
        XCTAssertEqual(failure.errorDescription, "the server answered HTTP 429")
        // The path a view actually takes.
        XCTAssertEqual((failure as Error).localizedDescription,
                       "the server answered HTTP 429")
    }

    func testEveryFailureHasSomethingToSay() {
        for failure: SpeedTest.Failure in [.unreachable("x"), .tooSlowToMeasure, .cancelled] {
            let text = (failure as Error).localizedDescription
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.contains("error 0"), text)
            XCTAssertFalse(text.contains("PowerKit"), text)
        }
    }
}
