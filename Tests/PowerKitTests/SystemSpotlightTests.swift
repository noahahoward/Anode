import XCTest
import CoreGraphics
@testable import AnodeApp

/// Whether the system's search is open is read from the window list; closing it is a key sent to the Siri process, which needs the
/// real thing and is checked on the Mac itself.
final class SystemSpotlightTests: XCTestCase {

    private func window(_ owner: String, pid: Int, alpha: Double?) -> [String: Any] {
        var w: [String: Any] = [kCGWindowOwnerName as String: owner, kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: 23]
        if let alpha { w[kCGWindowAlpha as String] = alpha }
        return w
    }

    func testItIsOpenWhenSiriHasAWindowThatCanBeSeen() {
        XCTAssertEqual(SystemSpotlight.openHost(in: [window("Safari", pid: 7, alpha: 1), window("Siri", pid: 1305, alpha: 1)], isSystemProcess: { _ in true }), 1305)
    }

    /// Closed, the panel's window stays in the list at alpha 0 (and fades through the values between while it closes).
    func testAFadedWindowIsClosed() {
        XCTAssertNil(SystemSpotlight.openHost(in: [window("Siri", pid: 1305, alpha: 0)], isSystemProcess: { _ in true }))
        XCTAssertNil(SystemSpotlight.openHost(in: [window("Siri", pid: 1305, alpha: 0.001)], isSystemProcess: { _ in true }))
        XCTAssertEqual(SystemSpotlight.openHost(in: [window("Siri", pid: 1305, alpha: 0.5)], isSystemProcess: { _ in true }), 1305)
    }

    func testOtherAppsWindowsAndAnEmptyListAreNotIt() {
        XCTAssertNil(SystemSpotlight.openHost(in: [], isSystemProcess: { _ in true }))
        XCTAssertNil(SystemSpotlight.openHost(in: [window("Anode", pid: 9, alpha: 1), window("Finder", pid: 10, alpha: 1)], isSystemProcess: { _ in true }))
    }

    /// Only a name: a program that calls itself "Siri" is not the system's, and is sent nothing.
    func testAProcessThatIsNotTheSystemsIsNotIt() {
        XCTAssertNil(SystemSpotlight.openHost(in: [window("Siri", pid: 4242, alpha: 1)], isSystemProcess: { $0 == 1305 }))
        XCTAssertEqual(SystemSpotlight.openHost(in: [window("Siri", pid: 4242, alpha: 1), window("Siri", pid: 1305, alpha: 1)],
                                                isSystemProcess: { $0 == 1305 }), 1305)
        XCTAssertFalse(SystemSpotlight.isSystemProcess(getpid()), "this test program is not in /System")
    }

    func testAWindowWithNoAlphaListedCountsAsVisible() {
        XCTAssertEqual(SystemSpotlight.openHost(in: [window("Siri", pid: 1305, alpha: nil)], isSystemProcess: { _ in true }), 1305)
    }
}
