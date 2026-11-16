import XCTest
@testable import PowerKit

/// The Sound icon in the menu bar: which glyph for which volume and which output.
final class SoundIconTests: XCTestCase {

    func testMutedAlwaysShowsTheSlashedSpeakerOnSpeakers() {
        XCTAssertEqual(SoundIcon.symbol(volume: 0.8, muted: true, output: .speakers), "speaker.slash.fill")
    }

    func testBandsOnSpeakers() {
        XCTAssertEqual(SoundIcon.symbol(volume: 0.0, muted: false, output: .speakers), "speaker.fill")
        XCTAssertEqual(SoundIcon.symbol(volume: 0.2, muted: false, output: .speakers), "speaker.wave.1.fill")
        XCTAssertEqual(SoundIcon.symbol(volume: 0.5, muted: false, output: .speakers), "speaker.wave.2.fill")
        XCTAssertEqual(SoundIcon.symbol(volume: 0.9, muted: false, output: .speakers), "speaker.wave.3.fill")
    }

    func testAirPodsShowTheirOwnGlyphAtAnyVolume() {
        XCTAssertEqual(SoundIcon.symbol(volume: 0.1, muted: false, output: .airpodsPro), "airpods.pro")
        XCTAssertEqual(SoundIcon.symbol(volume: 0.9, muted: true, output: .airpodsPro), "airpods.pro")
        XCTAssertEqual(SoundIcon.symbol(volume: 0.5, muted: false, output: .airpods), "airpods")
    }

    func testGuessFromNameAndTransport() {
        XCTAssertEqual(OutputKind.guess(name: "MacBook Pro Speakers", transport: "bltn"), .speakers)
        XCTAssertEqual(OutputKind.guess(name: "Test AirPods Pro", transport: "blue"), .airpodsPro)
        XCTAssertEqual(OutputKind.guess(name: "Test AirPods Max", transport: "blue"), .airpods)
        XCTAssertEqual(OutputKind.guess(name: "Some Headset", transport: "blue"), .headphones)
        XCTAssertEqual(OutputKind.guess(name: "Living Room Speaker", transport: "airp"), .hifi)
        XCTAssertEqual(OutputKind.guess(name: "Den TV", transport: "airp"), .display)
        XCTAssertEqual(OutputKind.guess(name: "Kitchen", transport: "airp"), .airplay)
    }

    func testProductIDBeatsAnOwnerChosenName() {
        XCTAssertEqual(OutputKind.guess(name: "My Ears", transport: "blue", productID: 8228), .airpodsPro)
        XCTAssertEqual(OutputKind.guess(name: "My Ears", transport: "blue", productID: nil), .headphones)
    }
}
