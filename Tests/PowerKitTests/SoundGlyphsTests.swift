import XCTest
@testable import PowerKit
@testable import AnodeApp

/// The glyph of an output row, as macOS draws it.
final class SoundGlyphsTests: XCTestCase {
    // Measured on macOS's own panel with a temporary aggregate device (transport 'grup'): an output of no known kind is drawn as the
    // speaker with two sound waves, not as a hi-fi speaker.
    func testAnOutputOfNoKnownKindIsTheSpeakerWithWaves() {
        XCTAssertEqual(OutputKind.guess(name: "Audit Output", transport: "grup"), .other)
        XCTAssertEqual(SoundGlyphs.output(.other), "speaker.wave.2.fill")
    }

    func testAHiFiSpeakerKeepsItsOwnGlyph() {
        XCTAssertEqual(SoundGlyphs.output(.hifi), "hifispeaker.fill")
    }
}
