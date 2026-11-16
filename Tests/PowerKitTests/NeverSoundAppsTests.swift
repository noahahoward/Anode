import XCTest
@testable import PowerKit

/// Apps that have no way to make sound are left off the Apps list; everything else open is on it.
final class NeverSoundAppsTests: XCTestCase {
    func testTheAppsThePersonNamedAreOnTheList() {
        XCTAssertTrue(NeverSoundApps.contains("com.apple.finder"))
        XCTAssertTrue(NeverSoundApps.contains("com.apple.Terminal"))
    }
    func testAnythingElseIsNot() {
        XCTAssertFalse(NeverSoundApps.contains("com.brave.Browser"))
        XCTAssertFalse(NeverSoundApps.contains("com.apple.Music"))
        XCTAssertFalse(NeverSoundApps.contains("com.apple.Safari"))
    }
}
