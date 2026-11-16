import XCTest
@testable import PowerKit

/// Many audio processes (a browser's helpers) are one app to the person: they are grouped under the app that holds them.
final class AudioAppGroupingTests: XCTestCase {

    private let brave = "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
    private let braveHelper = "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework/Versions/1/Helpers/Brave Browser Helper.app/Contents/MacOS/Brave Browser Helper"

    func testTheOutermostAppIsFoundThroughNestedHelpers() {
        XCTAssertEqual(AudioAppGrouping.outermostAppPath(braveHelper), "/Applications/Brave Browser.app")
        XCTAssertEqual(AudioAppGrouping.outermostAppPath(brave), "/Applications/Brave Browser.app")
    }

    func testAToolOrADirectoryThatOnlyLooksLikeAnAppIsNotAnApp() {
        XCTAssertNil(AudioAppGrouping.outermostAppPath("/usr/bin/afplay"))
        XCTAssertNil(AudioAppGrouping.outermostAppPath("/tmp/x.application/y"))
        XCTAssertNil(AudioAppGrouping.outermostAppPath(""))
    }

    private func process(_ id: UInt32, _ path: String, playing: Bool = false) -> AudioProcessInfo {
        AudioProcessInfo(objectID: id, pid: Int32(id) + 1000, executablePath: path, isRunningOutput: playing)
    }

    private func group(_ list: [AudioProcessInfo]) -> [AudioApp] {
        AudioAppGrouping.group(list, bundleID: { path in
            path.contains("Brave") ? "com.brave.Browser" : path.contains("Music") ? "com.apple.Music" : path.contains("Zed") ? "dev.zed" : nil
        }, name: { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent })
    }

    func testAnAppAndItsHelpersAreOneApp() {
        let apps = group([process(1, brave), process(2, braveHelper, playing: true), process(3, braveHelper), process(4, braveHelper)])
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps[0].bundleID, "com.brave.Browser")
        XCTAssertEqual(apps[0].name, "Brave Browser")
        XCTAssertEqual(apps[0].processObjectIDs.sorted(), [1, 2, 3, 4])
        XCTAssertTrue(apps[0].isPlaying)
    }

    func testTwoAppsAreTwoApps_AndAProcessWithoutAnAppIsLeftOut() {
        let apps = group([process(1, brave), process(2, "/System/Applications/Music.app/Contents/MacOS/Music"), process(3, "/usr/bin/afplay")])
        XCTAssertEqual(Set(apps.map(\.bundleID)), ["com.brave.Browser", "com.apple.Music"])
    }

    func testAnAppWithNoBundleIdentifierIsLeftOut() {
        XCTAssertTrue(group([process(1, "/Applications/Unknown.app/Contents/MacOS/Unknown")]).isEmpty)
    }

    func testTheOrderIsPlayingFirstThenByNameWhateverTheCase() {
        let apps = group([process(1, "/Applications/Zed.app/Contents/MacOS/Zed"), process(2, "/System/Applications/Music.app/Contents/MacOS/Music"),
                          process(3, brave, playing: true)])
        XCTAssertEqual(apps.map(\.name), ["Brave Browser", "Music", "Zed"])
    }
}
