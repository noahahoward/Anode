import XCTest
import AppKit
@testable import AnodeApp
@testable import PowerKit

/// The Live Wallpapers section of Beta Features, driven the way clicks would drive it. The importer is a fake that adds to a
/// real library in a temp folder; the controller (when one is needed) is the real one over fake surfaces. Nothing is shown.
@MainActor
final class LiveWallpaperFeatureTests: XCTestCase {

    private typealias Fakes = LiveWallpaperControllerTests

    final class FakeImporter: LiveWallpaperImporting {
        let library: WallpaperLibrary
        var calls: [String] = []
        var warnings: [String] = []
        var failure: Error?
        var linkDownloadCopy: Bool?
        var cancelled = 0
        init(library: WallpaperLibrary) { self.library = library }

        private func add(_ name: String, _ kind: WallpaperKind) throws -> ImportResult {
            if let failure { throw failure }
            let it = WallpaperItem(name: name, kind: kind, source: .remote(URL(string: "https://example.com/\(name)")!),
                                   posterFilename: nil, thumbnailFilename: nil, durationSeconds: nil, pixelWidth: nil, pixelHeight: nil,
                                   codec: nil, hasAudio: nil, hardwareDecodable: nil)
            try library.add(it)
            return ImportResult(item: it, warnings: warnings)
        }
        func addFile(_ url: URL) async throws -> ImportResult {
            calls.append("file:\(url.lastPathComponent)")
            let kind: WallpaperKind = ["png", "jpg"].contains(url.pathExtension) ? .image : (url.pathExtension == "html" ? .web : .video)
            return try add(url.deletingPathExtension().lastPathComponent, kind)
        }
        func addFolder(_ url: URL) async throws -> ImportResult {
            calls.append("folder:\(url.lastPathComponent)")
            return try add(url.lastPathComponent, .web)
        }
        func addLink(_ url: URL, downloadCopy: Bool, progress: @escaping (Double) -> Void) async throws -> ImportResult {
            calls.append("link:\(url.absoluteString)")
            linkDownloadCopy = downloadCopy
            return try add(url.host ?? "link", .video)
        }
        func cancel() { cancelled += 1 }
    }

    private struct Rig {
        let feature: LiveWallpaperFeature
        let library: WallpaperLibrary
        let store: WallpaperPrefsStore
        let settings: Settings
        let importer: FakeImporter
        let displays: Fakes.Box<[DisplayInfo]>
        let controller: LiveWallpaperController
        let factory: Fakes.FakeFactory
        let dir: URL
        let defaults: UserDefaults
        let suite: String
    }

    private func display(_ id: String, _ name: String) -> DisplayInfo {
        DisplayInfo(uuid: id, name: name, frame: NSRect(x: 0, y: 0, width: 1000, height: 600), pixelSize: CGSize(width: 2000, height: 1200))
    }

    private func rig(enabled: Bool = true) throws -> Rig {
        let (defaults, suite) = try TestDefaults.make(owner: "LiveWallpaperFeature", test: name)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LWF-\(UUID().uuidString)")
        let settings = Settings(defaults: defaults)
        settings.liveWallpaperEnabled = enabled
        let library = WallpaperLibrary(directory: dir)
        let store = WallpaperPrefsStore(defaults: defaults)
        let importer = FakeImporter(library: library)
        let displays = Fakes.Box([display("D1", "Built-in"), display("D2", "Studio Display")])
        let factory = Fakes.FakeFactory()
        let controller = LiveWallpaperController(settings: settings, library: library, prefsStore: store, displays: { displays.value },
                                                 factory: factory, conditions: { WallpaperGlobalConditions() }, now: { Date() })
        let feature = LiveWallpaperFeature(settings: settings, library: library, prefsStore: store, store: ShortcutStore(defaults: defaults),
                                           displays: { displays.value }, controller: { controller }, importer: importer)
        _ = feature.makeView()
        return Rig(feature: feature, library: library, store: store, settings: settings, importer: importer, displays: displays,
                   controller: controller, factory: factory, dir: dir, defaults: defaults, suite: suite)
    }

    private func done(_ r: Rig) {
        r.controller.shutdown()
        try? FileManager.default.removeItem(at: r.dir)
        TestDefaults.destroy(r.defaults, r.suite)
    }

    @discardableResult
    private func add(_ r: Rig, _ name: String, _ kind: WallpaperKind = .video, source: WallpaperSource? = nil) throws -> WallpaperItem {
        let it = WallpaperItem(name: name, kind: kind, source: source ?? .remote(URL(string: "https://example.com/\(name)")!),
                               posterFilename: nil, thumbnailFilename: nil, durationSeconds: nil, pixelWidth: nil, pixelHeight: nil,
                               codec: nil, hasAudio: nil, hardwareDecodable: nil)
        try r.library.add(it)
        r.feature.refresh()
        return it
    }

    private func choose(_ popUp: NSPopUpButton, _ index: Int) {
        popUp.selectItem(at: index)
        popUp.sendAction(popUp.action, to: popUp.target)
    }

    // MARK: the checkbox

    func testTheCheckboxWritesTheSettingAndWhileOffOnlyItIsShown() throws {
        let r = try rig(enabled: false); defer { done(r) }
        XCTAssertEqual(r.feature.enableCheckbox.state, .off)
        XCTAssertTrue(r.feature.bodyStack.isHidden, "while off, everything but the checkbox is hidden")
        r.feature.enableCheckbox.performClick(nil)
        XCTAssertTrue(r.settings.liveWallpaperEnabled)
        XCTAssertFalse(r.feature.bodyStack.isHidden)
        r.feature.enableCheckbox.performClick(nil)
        XCTAssertFalse(r.settings.liveWallpaperEnabled)
        XCTAssertTrue(r.feature.bodyStack.isHidden)
    }

    func testTheSummaryIsHonestAboutMaximizedWindowsAndTheMenuBar() throws {
        let r = try rig(); defer { done(r) }
        XCTAssertTrue(r.feature.summary.contains("menu bar"))
        XCTAssertTrue(r.feature.coveredCheckbox.title.lowercased().contains("full-screen"))
        XCTAssertFalse(r.feature.coveredCheckbox.title.lowercased().contains("maximi"), "it does not pause behind a maximized window")
    }

    // MARK: adding

    func testAddFileRunsTheImporterForAVideoAnImageAndAnHTMLFileAlike() async throws {
        let r = try rig(); defer { done(r) }
        r.importer.warnings = ["This video uses software decoding, which costs more battery."]
        for name in ["wave.mov", "photo.png", "page.html"] {
            await r.feature.importFile(URL(fileURLWithPath: "/tmp/\(name)"))
        }
        XCTAssertEqual(r.importer.calls, ["file:wave.mov", "file:photo.png", "file:page.html"])
        XCTAssertEqual(r.feature.libraryRows.map(\.item.name), ["wave", "photo", "page"], "a row per new item")
        XCTAssertTrue(r.feature.messageLabel.stringValue.contains("software decoding"), "its warnings are visible")
    }

    func testAddFolderAndAddLinkRunTheImporterToo() async throws {
        let r = try rig(); defer { done(r) }
        await r.feature.importFolder(URL(fileURLWithPath: "/tmp/site"))
        await r.feature.submitLink("https://example.com/clip.mp4", downloadCopy: false)
        XCTAssertEqual(r.importer.calls, ["folder:site", "link:https://example.com/clip.mp4"])
        XCTAssertEqual(r.importer.linkDownloadCopy, false)
        XCTAssertEqual(r.feature.libraryRows.count, 2)
    }

    func testTheLinkPromptOffersToDownloadACopyByDefault() throws {
        let r = try rig(); defer { done(r) }
        let prompt = r.feature.makeLinkPrompt()
        XCTAssertEqual(prompt.downloadCheckbox.state, .on)
        XCTAssertEqual(prompt.downloadCheckbox.title, "Download a copy (recommended)")
    }

    func testAnHTTPLinkIsRefusedWithAMessageAndNothingIsImported() async throws {
        let r = try rig(); defer { done(r) }
        await r.feature.submitLink("http://example.com/clip.mp4", downloadCopy: true)
        XCTAssertTrue(r.feature.messageLabel.stringValue.contains("https"))
        XCTAssertEqual(r.importer.calls, [])
        await r.feature.submitLink("not a link", downloadCopy: true)
        XCTAssertFalse(r.feature.messageLabel.stringValue.isEmpty)
        XCTAssertEqual(r.importer.calls, [])
    }

    func testAllTheUIWorkOfAnImportHappensOnTheMainThread() async throws {
        // The importer runs wherever Swift puts it; the section's own buttons, labels and rows must never be touched off main.
        let r = try rig(); defer { done(r) }
        var offMain = 0, total = 0
        r.feature.layoutChanged = { total += 1; if !Thread.isMainThread { offMain += 1 } }
        await r.feature.importFile(URL(fileURLWithPath: "/tmp/wave.mov"))
        await r.feature.submitLink("https://example.com/clip.mp4", downloadCopy: false)
        XCTAssertGreaterThan(total, 0)
        XCTAssertEqual(offMain, 0, "\(offMain) of \(total) UI updates ran off the main thread")
    }

    func testAFailedImportSaysWhyAndAddsNothing() async throws {
        let r = try rig(); defer { done(r) }
        r.importer.failure = WallpaperImportError.notPlayable
        await r.feature.importFile(URL(fileURLWithPath: "/tmp/bad.mov"))
        XCTAssertEqual(r.feature.messageLabel.stringValue, WallpaperImportError.notPlayable.message)
        XCTAssertEqual(r.feature.libraryRows.count, 0)
        XCTAssertTrue(r.feature.addFileButton.isEnabled, "buttons come back after a failure")
    }

    func testTheFirstItemAddedBecomesTheDefaultAndLaterOnesDoNot() async throws {
        let r = try rig(); defer { done(r) }
        await r.feature.importFile(URL(fileURLWithPath: "/tmp/one.mov"))
        let first = try XCTUnwrap(r.library.items.first)
        XCTAssertEqual(r.store.prefs.assignments.defaultItem, first.id)
        await r.feature.importFile(URL(fileURLWithPath: "/tmp/two.mov"))
        XCTAssertEqual(r.store.prefs.assignments.defaultItem, first.id)
    }

    // MARK: assignments

    func testEachDisplayHasAPopupWithSameAsDefaultNoneAndEveryItem() throws {
        let r = try rig(); defer { done(r) }
        let a = try add(r, "Alpha"), b = try add(r, "Beta")
        XCTAssertEqual(r.feature.displayRows.map(\.displayUUID), ["D1", "D2"])
        let row = try XCTUnwrap(r.feature.displayRows.first)
        XCTAssertEqual(row.popUp.itemTitles, ["Same as default", "None", "Alpha", "Beta"])
        choose(row.popUp, 3)
        XCTAssertEqual(r.store.prefs.assignments.perDisplay["D1"], .item(b.id))
        choose(row.popUp, 1)
        XCTAssertEqual(r.store.prefs.assignments.perDisplay["D1"], DisplayChoice.none)
        choose(row.popUp, 0)
        XCTAssertNil(r.store.prefs.assignments.perDisplay["D1"])
        _ = a
    }

    func testTheDefaultPopupSetsTheDefaultItem() throws {
        let r = try rig(); defer { done(r) }
        let a = try add(r, "Alpha")
        XCTAssertEqual(r.feature.defaultPopUp.itemTitles, ["None", "Alpha"])
        choose(r.feature.defaultPopUp, 1)
        XCTAssertEqual(r.store.prefs.assignments.defaultItem, a.id)
        choose(r.feature.defaultPopUp, 0)
        XCTAssertNil(r.store.prefs.assignments.defaultItem)
    }

    func testTheRowsFollowTheDisplaysThatAreConnected() throws {
        let r = try rig(); defer { done(r) }
        r.displays.value = [display("D1", "Built-in")]
        r.feature.refresh()
        XCTAssertEqual(r.feature.displayRows.map(\.displayUUID), ["D1"])
    }

    // MARK: preferences

    func testThePauseRuleCheckboxesWritePrefs() throws {
        let r = try rig(); defer { done(r) }
        XCTAssertEqual([r.feature.batteryCheckbox, r.feature.lowPowerCheckbox, r.feature.coveredCheckbox, r.feature.hotCheckbox].map(\.state),
                       [.on, .on, .on, .on])
        r.feature.batteryCheckbox.performClick(nil);  XCTAssertFalse(r.store.prefs.pauseOnBattery)
        r.feature.lowPowerCheckbox.performClick(nil); XCTAssertFalse(r.store.prefs.pauseInLowPower)
        r.feature.coveredCheckbox.performClick(nil);  XCTAssertFalse(r.store.prefs.pauseWhenCovered)
        r.feature.hotCheckbox.performClick(nil);      XCTAssertFalse(r.store.prefs.pauseWhenHot)
        r.feature.batteryCheckbox.performClick(nil);  XCTAssertTrue(r.store.prefs.pauseOnBattery)
    }

    func testScalingMuteVolumeAndSpeedWritePrefs() throws {
        let r = try rig(); defer { done(r) }
        let v = try add(r, "Clip", .video)
        var p = r.store.prefs; p.assignments.defaultItem = v.id; r.store.prefs = p
        r.feature.refresh()

        choose(r.feature.scalingPopUp, WallpaperScaling.allCases.firstIndex(of: .fit)!)
        XCTAssertEqual(r.store.prefs.scaling, .fit)

        r.feature.muteCheckbox.performClick(nil)
        XCTAssertFalse(r.store.prefs.muted)

        r.feature.volumeSlider.doubleValue = 0.8
        r.feature.volumeSlider.sendAction(r.feature.volumeSlider.action, to: r.feature.volumeSlider.target)
        XCTAssertEqual(r.store.prefs.volume, 0.8, accuracy: 0.001)

        r.feature.speedSlider.doubleValue = 1.5
        r.feature.speedSlider.sendAction(r.feature.speedSlider.action, to: r.feature.speedSlider.target)
        XCTAssertEqual(r.store.prefs.speed, 1.5, accuracy: 0.001)
        XCTAssertEqual(r.feature.speedSlider.minValue, 0.25)
        XCTAssertEqual(r.feature.speedSlider.maxValue, 2.0)
    }

    func testSpeedAndSoundAreDisabledWhenNothingAssignedCanUseThem() throws {
        let r = try rig(); defer { done(r) }
        XCTAssertFalse(r.feature.speedSlider.isEnabled, "nothing assigned")
        XCTAssertFalse(r.feature.muteCheckbox.isEnabled)
        let pic = try add(r, "Pic", .image)
        var p = r.store.prefs; p.assignments.defaultItem = pic.id; r.store.prefs = p
        r.feature.refresh()
        XCTAssertFalse(r.feature.speedSlider.isEnabled, "an image has no speed")
        XCTAssertFalse(r.feature.muteCheckbox.isEnabled, "an image has no sound")
        let web = try add(r, "Page", .web)
        p = r.store.prefs; p.assignments.setChoice(.item(web.id), forDisplay: "D2"); r.store.prefs = p
        r.feature.refresh()
        XCTAssertTrue(r.feature.muteCheckbox.isEnabled, "a web page can have sound")
        XCTAssertFalse(r.feature.speedSlider.isEnabled, "but only a video has a speed")
        let vid = try add(r, "Clip", .video)
        p = r.store.prefs; p.assignments.setChoice(.item(vid.id), forDisplay: "D1"); r.store.prefs = p
        r.feature.refresh()
        XCTAssertTrue(r.feature.speedSlider.isEnabled)
    }

    func testTheVolumeSliderFollowsTheMuteCheckbox() throws {
        let r = try rig(); defer { done(r) }
        let v = try add(r, "Clip", .video)
        var p = r.store.prefs; p.assignments.defaultItem = v.id; r.store.prefs = p
        r.feature.refresh()
        XCTAssertFalse(r.feature.volumeSlider.isEnabled, "muted by default")
        r.feature.muteCheckbox.performClick(nil)
        XCTAssertTrue(r.feature.volumeSlider.isEnabled)
    }

    // MARK: status, failure, missing files, removal

    func testAFailedStatusShowsItsTextWithAReloadButtonThatRetries() throws {
        let r = try rig(); defer { done(r) }
        let bad = try add(r, "Flaky")
        r.factory.refuse = ["Flaky"]
        var p = r.store.prefs; p.assignments.defaultItem = bad.id; r.store.prefs = p
        r.controller.reconcile()
        r.feature.refresh()
        let row = try XCTUnwrap(r.feature.displayRows.first)
        XCTAssertTrue(row.statusLabel.stringValue.contains("Couldn't show Flaky"), row.statusLabel.stringValue)
        XCTAssertFalse(row.reloadButton.isHidden)
        r.factory.refuse = []
        row.reloadButton.performClick(nil)
        XCTAssertNotNil(r.factory.live(for: "D1"))
        r.feature.refresh()
        XCTAssertTrue(r.feature.displayRows.first?.reloadButton.isHidden ?? false)
        XCTAssertTrue(r.feature.displayRows.first?.statusLabel.stringValue.contains("Playing") ?? false)
    }

    func testAMissingFileItemSaysSoAndOffersRemove() throws {
        let r = try rig(); defer { done(r) }
        let gone = try add(r, "Gone", .video, source: .file("gone.mov"))
        let row = try XCTUnwrap(r.feature.libraryRows.first { $0.item.id == gone.id })
        XCTAssertTrue(row.detailLabel.stringValue.contains("File missing"))
        XCTAssertFalse(row.removeButton.isHidden)
    }

    func testRemoveDeletesTheItemAndClearsItsAssignments() throws {
        let r = try rig(); defer { done(r) }
        let a = try add(r, "A")
        var p = r.store.prefs; p.assignments.defaultItem = a.id; p.assignments.setChoice(.item(a.id), forDisplay: "D2"); r.store.prefs = p
        r.feature.remove(a.id)
        XCTAssertEqual(r.library.items, [])
        XCTAssertNil(r.store.prefs.assignments.defaultItem)
        XCTAssertNil(r.store.prefs.assignments.perDisplay["D2"])
        XCTAssertEqual(r.feature.libraryRows.count, 0)
    }

    func testPlayingStatusIsShownPerDisplay() throws {
        let r = try rig(); defer { done(r) }
        let a = try add(r, "Clip")
        var p = r.store.prefs; p.assignments.defaultItem = a.id; r.store.prefs = p
        r.controller.reconcile()
        r.feature.refresh()
        XCTAssertTrue(r.feature.displayRows[0].statusLabel.stringValue.contains("Playing"))
        r.controller.setUserPaused(true)
        r.feature.refresh()
        XCTAssertTrue(r.feature.displayRows[0].statusLabel.stringValue.lowercased().contains("paused"))
    }

    // MARK: pause button

    func testThePauseButtonTogglesTheUserPauseAndItsTitleFollows() throws {
        let r = try rig(); defer { done(r) }
        XCTAssertEqual(r.feature.pauseButton.title, "Pause wallpaper")
        r.feature.pauseButton.performClick(nil)
        XCTAssertTrue(r.controller.userPaused)
        XCTAssertEqual(r.feature.pauseButton.title, "Resume wallpaper")
        r.feature.pauseButton.performClick(nil)
        XCTAssertFalse(r.controller.userPaused)
        XCTAssertEqual(r.feature.pauseButton.title, "Pause wallpaper")
    }

    func testTheSectionNamesThePauseShortcut() throws {
        let r = try rig(); defer { done(r) }
        XCTAssertTrue(r.feature.shortcutNote.stringValue.contains("⌃⌥⌘W"))
    }

    func testTheFeatureIsInTheBetaFeaturesWindow() {
        XCTAssertTrue(BetaFeaturesWindowController().features.contains { $0 is LiveWallpaperFeature })
    }
}

private extension NSPopUpButton {
    var itemTitles: [String] { itemArray.map(\.title) }
}
