import XCTest
@testable import PowerKit
@testable import AnodeApp

/// A change macOS refused (Adaptive with one AirPod in) left the open AirPods row drawn over its own "Listening Mode" heading until
/// the menu was drawn again. Recorded through Accessibility on the owner's Mac: the row went from 32 pt tall, where it belongs, to the
/// frame of the lighter block under it (y 325, 249 pt tall) when the refusal's line appeared and the menu glided to its new height.
/// The block is put behind the rows already drawn (low in the list of subviews), and the views a row made were taken to be the last
/// ones in that list: for the block that was the device row above it, which every glide then moved as the block.
final class SoundMenuGlideTests: XCTestCase {

    private let pods = "Test AirPods Pro"

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        DisplayAccessibility.override = DisplayAccessibility()   // glides are on (Reduce Motion off), whatever this Mac is set to
    }

    override func tearDown() { DisplayAccessibility.override = nil; super.tearDown() }

    private func model(notice: String?) -> SoundMenuModel {
        func rows(_ section: String, _ titles: [String]) -> [AppleChoiceRow] {
            titles.enumerated().map { AppleChoiceRow(section: section, title: $0.element, isOn: $0.offset == 0, enabled: true, device: pods) }
        }
        return SoundMenuModel(volume: 0.5, muted: false,
                              devices: [.init(id: "a", name: "MacBook Pro Speakers", kind: .speakers, isSelected: false),
                                        .init(id: "b", name: pods, kind: .airpodsPro, isSelected: true),
                                        .init(id: nil, name: "Living Room", kind: .airplay, isSelected: false)],
                              expandedDevice: pods,
                              listening: rows(AppleSoundPanel.listeningHeading, ["Transparency", "Adaptive", "Noise Cancellation"]),
                              spatial: [],
                              conversation: rows(AppleSoundPanel.conversationHeading, ["Off", "On"]),
                              appleAvailable: true, notice: notice)
    }

    /// The rows drawn, each as its kind and its frame in the menu, in a stable order (new rows sit in the clip, in the same coordinates).
    private func drawn(_ view: NSView) -> [String] {
        var out: [String] = []
        for s in view.subviews {
            let inner = String(describing: type(of: s)) == "ClipView" ? s.subviews : [s]
            for v in inner { out.append("\(type(of: v)) \(view.convert(v.bounds, from: v))") }
        }
        return out.sorted()
    }

    private func podsRow(in view: NSView) -> NSView? {
        var all: [NSView] = []
        for s in view.subviews { all.append(s); all += s.subviews }
        return all.first { $0 is DeviceRow && $0.accessibilityLabel() == pods }
    }

    func testAGlideWithADeviceOpenEndsWithEveryRowWhereAFreshDrawingPutsIt() {
        let menu = SoundMenuContentView()
        menu.apply(model(notice: nil))
        XCTAssertTrue(menu.apply(model(notice: "Put both AirPods in."), animated: true), "the line under the rows changes the height: it glides")
        menu.finishGlide()
        let fresh = SoundMenuContentView()
        fresh.apply(model(notice: "Put both AirPods in."))
        XCTAssertEqual(drawn(menu), drawn(fresh))
    }

    func testTheOpenDeviceRowStaysARowThroughTheGlide() throws {
        let menu = SoundMenuContentView()
        menu.apply(model(notice: nil))
        let before = try XCTUnwrap(podsRow(in: menu)).frame
        XCTAssertTrue(menu.apply(model(notice: "Put both AirPods in."), animated: true))
        for p in [0.0, 0.5, 1.0] as [CGFloat] {
            menu.step(p)
            let row = try XCTUnwrap(podsRow(in: menu))
            XCTAssertEqual(row.frame.height, before.height, "at \(p) of the way the row is the size of a row, not of the block under it")
            XCTAssertEqual(row.frame.minY, before.minY, accuracy: 0.5, "nothing above it changed: it does not move")
        }
    }
}
