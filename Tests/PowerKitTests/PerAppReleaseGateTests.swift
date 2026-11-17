import XCTest
@testable import PowerKit
@testable import AnodeApp

/// Per-app volume is offered wherever process taps exist, on the process-list taps. The bundle-id taps stay off: a tap named after an
/// app never heard a browser's sound (it comes from a helper with another id).
final class PerAppReleaseGateTests: XCTestCase {
    func testThePerAppSwitchIsOfferedOnThisMac() {
        XCTAssertTrue(CoreAudioAppBackend.isReleaseReady)
    }

    func testBundleIdTapsStayOff() {
        XCTAssertFalse(CoreAudioAppBackend.bundleTapsVerified)
        XCTAssertFalse(CoreAudioAppBackend().canTapAppsNotYetRunning)
    }
}
