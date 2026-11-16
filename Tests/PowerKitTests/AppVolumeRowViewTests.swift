import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// The app rows of the Sound menu as drawn: a change to one app is shown on its row (so the knob can glide), not by drawing the
/// whole menu again; and the row has no name on it, only a tooltip.
final class AppVolumeRowViewTests: XCTestCase {

    private func model(_ apps: [AppVolumeRow], volume: Double = 0.5) -> SoundMenuModel {
        var m = SoundMenuModel(volume: volume, muted: false,
                               devices: [SoundMenuModel.Device(id: "b", name: "MacBook Pro Speakers", kind: .speakers, isSelected: true)],
                               expandedDevice: nil, listening: [], spatial: [], conversation: [], appleAvailable: true)
        m.apps = apps
        return m
    }

    private let player = AppVolumeRow(bundleID: "com.apple.finder", name: "Player", volume: 0.6, muted: false)

    func testMutingAnAppIsShownOnItsExistingRow() {
        let view = SoundMenuContentView(frame: NSRect(x: 0, y: 0, width: 309, height: 100))
        view.apply(model([player]))
        let row = try? XCTUnwrap(view.appRows[player.bundleID])
        var muted = player; muted.muted = true
        let rebuilt = view.apply(model([muted]), animated: true)
        XCTAssertFalse(rebuilt, "no glide of the whole menu: only the row changed")
        XCTAssertTrue(view.appRows[player.bundleID] === row, "the same row, so its knob can glide rather than be drawn afresh at zero")
    }

    func testAChangeOfTheOutputsStillDrawsEverythingAgain() {
        let view = SoundMenuContentView(frame: NSRect(x: 0, y: 0, width: 309, height: 100))
        view.apply(model([player]))
        let row = view.appRows[player.bundleID]
        view.apply(model([player], volume: 0.9), animated: true)
        XCTAssertFalse(view.appRows[player.bundleID] === row)
    }

    func testTheRowCarriesTheNameAsATooltipAndNotAsText() {
        let view = SoundMenuContentView(frame: NSRect(x: 0, y: 0, width: 309, height: 100))
        view.apply(model([player]))
        let row = view.appRows[player.bundleID]!
        let texts = row.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertFalse(texts.contains("Player"), "the name is not drawn on the row")
        XCTAssertTrue(row.subviews.contains { $0.toolTip == "Player" }, "it is the icon's tooltip")
        XCTAssertEqual(row.frame.height, SoundMenuMetrics.appRowHeight)
    }
}
