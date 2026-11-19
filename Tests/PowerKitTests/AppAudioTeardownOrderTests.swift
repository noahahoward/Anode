import XCTest

/// Setting an app back to 100 % while it played skipped half a second to a second of its music. The tap keeps the app silent until the
/// tap is gone, and `stop` took Anode's own device down first (stopping it, its IO block, the device itself: slow, a round trip to the
/// audio daemon each), so the app played on unheard for that long. The tap goes first now: the app's own sound is back at once, and the
/// rest comes down after it. (Keeping the tap at 100 % instead was refused: macOS shows a recording indicator while one exists.)
final class AppAudioTeardownOrderTests: XCTestCase {

    private func stopBody() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/AnodeApp/CoreAudioAppBackend.swift"), encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "    func stop() {"))
        return String(text[start.upperBound...].prefix(1800))
    }

    func testTheTapThatMutesTheAppGoesBeforeAnodesDevice() throws {
        let body = try stopBody()
        let tap = try XCTUnwrap(body.range(of: "AudioHardwareDestroyProcessTap"))
        for later in ["AudioDeviceStop", "AudioDeviceDestroyIOProcID", "AudioHardwareDestroyAggregateDevice"] {
            let at = try XCTUnwrap(body.range(of: later), "\(later) is not in stop()")
            XCTAssertLessThan(tap.lowerBound, at.lowerBound, "the app is unmuted (its tap gone) before \(later)")
        }
    }

    func testWhatGoesWrongOnceTheTapIsGoneIsNotTakenForAFailure() throws {
        // With the tap gone first, the device may report itself dead on the way down: that is not a failure to tell the person about.
        XCTAssertTrue(try stopBody().contains("stopped = true"))
    }
}
