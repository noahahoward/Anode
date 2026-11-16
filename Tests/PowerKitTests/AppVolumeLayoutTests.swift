import XCTest
@testable import PowerKit

/// The "Apps" section of the Sound menu (per-app volume): where it goes, and that nothing moves when there are no apps.
final class AppVolumeLayoutTests: XCTestCase {

    private func model(apps: [AppVolumeRow]) -> SoundMenuModel {
        var m = SoundMenuModel(volume: 0.5, muted: false,
                               devices: [SoundMenuModel.Device(id: "b", name: "MacBook Pro Speakers", kind: .speakers, isSelected: true)],
                               expandedDevice: nil, listening: [], spatial: [], conversation: [], appleAvailable: true)
        m.apps = apps
        return m
    }

    private let two = [AppVolumeRow(bundleID: "com.example.player", name: "Player", volume: 1, muted: false),
                       AppVolumeRow(bundleID: "com.example.browser", name: "Browser", volume: 0.4, muted: true)]

    func testNoAppsMeansTheMenuIsExactlyAsBefore() {
        let without = SoundMenuLayout.frames(for: model(apps: []))
        XCTAssertFalse(without.rows.contains { if case .app = $0.kind { return true }; return false })
        XCTAssertFalse(without.rows.contains { $0.kind == .heading("Apps") })
        XCTAssertEqual(without.rows.first { $0.kind == .heading("Output") }?.frame.minY, SoundMenuMetrics.outputHeadingY)
    }

    func testTheAppsSectionSitsUnderTheVolumeSliderAndPushesOutputDown() {
        let layout = SoundMenuLayout.frames(for: model(apps: two))
        let heading = layout.rows.first { $0.kind == .heading("Apps") }
        XCTAssertEqual(heading?.frame.minY, SoundMenuMetrics.outputHeadingY, "in the place Output's heading had")
        let appRows = layout.rows.filter { if case .app = $0.kind { return true }; return false }
        XCTAssertEqual(appRows.count, 2)
        XCTAssertEqual(appRows[0].frame.minY, SoundMenuMetrics.deviceRowsY)
        XCTAssertEqual(appRows[1].frame.minY, SoundMenuMetrics.deviceRowsY + SoundMenuMetrics.appRowHeight)
        let output = layout.rows.first { $0.kind == .heading("Output") }!
        XCTAssertEqual(output.frame.minY, SoundMenuMetrics.outputHeadingY + SoundMenuMetrics.appsSectionHeight(rows: 2), accuracy: 0.001)
        let plain = SoundMenuLayout.frames(for: model(apps: []))
        XCTAssertEqual(layout.height - plain.height, SoundMenuMetrics.appsSectionHeight(rows: 2), accuracy: 0.001,
                       "the panel is exactly as much taller as the section")
    }

    func testADividerSeparatesTheAppsFromOutput() {
        let layout = SoundMenuLayout.frames(for: model(apps: two))
        let dividers = layout.rows.filter { $0.kind == .divider }.map(\.frame.minY)
        XCTAssertEqual(dividers.count, 3, "under the slider, under the apps, over the footer")
        let output = layout.rows.first { $0.kind == .heading("Output") }!.frame.minY
        XCTAssertTrue(dividers.contains { $0 < output && $0 > SoundMenuMetrics.deviceRowsY + 2 * SoundMenuMetrics.appRowHeight })
    }

    func testAnAppRowHasRoomForANameAndASliderUnderIt() {
        XCTAssertEqual(SoundMenuMetrics.appRowHeight, 50)
        let layout = SoundMenuLayout.frames(for: model(apps: two))
        XCTAssertEqual(layout.rows.first { if case .app = $0.kind { return true }; return false }?.frame.width, SoundMenuMetrics.rowWidth)
    }

    func testTheModelCarriesTheAppsThroughTheMerge() {
        var m = SoundMenuModel.merge(outputs: [OutputDevice(id: "b", name: "MacBook Pro Speakers", kind: .speakers)], defaultID: "b",
                                     volume: 0.5, muted: false, batteries: [], apple: nil)
        XCTAssertTrue(m.apps.isEmpty, "none unless something supplies them")
        m.apps = two
        XCTAssertEqual(m.apps.map(\.name), ["Player", "Browser"])
    }

    func testAnAppsVolumeIsKeptBetweenZeroAndOneHundredPercent() {
        XCTAssertEqual(AppVolumeRow(bundleID: "a", name: "A", volume: 1.7, muted: false).volume, 1)
        XCTAssertEqual(AppVolumeRow(bundleID: "a", name: "A", volume: -0.2, muted: false).volume, 0)
        XCTAssertEqual(AppVolumeRow(bundleID: "a", name: "A", volume: 0.5, muted: false).percentText, "50%")
    }
}
