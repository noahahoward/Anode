import XCTest
@testable import PowerKit

/// Live wallpaper preferences and the display → item assignments.
final class WallpaperPrefsTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        (defaults, suiteName) = try TestDefaults.make(owner: "WallpaperPrefs", test: name)
    }

    override func tearDownWithError() throws {
        TestDefaults.destroy(defaults, suiteName)
    }

    // MARK: the setting

    func testLiveWallpaperIsOffByDefaultAndPersists() {
        XCTAssertFalse(Settings(defaults: defaults).liveWallpaperEnabled)
        Settings(defaults: defaults).liveWallpaperEnabled = true
        XCTAssertTrue(Settings(defaults: defaults).liveWallpaperEnabled)
    }

    func testTheSettingNotifiesOnlyOnARealChange() {
        let s = Settings(defaults: defaults)
        var fired = 0
        let token = s.observe(Settings.Key.liveWallpaperEnabled) { fired += 1 }
        s.liveWallpaperEnabled = true
        s.liveWallpaperEnabled = true
        XCTAssertEqual(fired, 1)
        s.liveWallpaperEnabled = false
        XCTAssertEqual(fired, 2)
        _ = token
    }

    // MARK: prefs

    func testDefaultsAreTheDocumentedOnes() {
        let p = WallpaperPrefs()
        XCTAssertTrue(p.pauseOnBattery)
        XCTAssertTrue(p.pauseInLowPower)
        XCTAssertTrue(p.pauseWhenCovered)
        XCTAssertTrue(p.pauseWhenHot)
        XCTAssertTrue(p.muted)
        XCTAssertEqual(p.volume, 0.5)
        XCTAssertEqual(p.scaling, .fill)
        XCTAssertEqual(p.speed, 1.0)
        XCTAssertEqual(p.assignments, WallpaperAssignments())
    }

    func testSpeedAndVolumeClamp() {
        var p = WallpaperPrefs()
        p.speed = 9; XCTAssertEqual(p.speed, 2.0)
        p.speed = 0.01; XCTAssertEqual(p.speed, 0.25)
        p.volume = 3; XCTAssertEqual(p.volume, 1)
        p.volume = -1; XCTAssertEqual(p.volume, 0)
        XCTAssertEqual(WallpaperPrefs.speedRange, 0.25...2.0)
    }

    func testClampingAlsoAppliesToWhatIsDecoded() throws {
        let json = #"{"speed": 50, "volume": 7}"#.data(using: .utf8)!
        let p = try JSONDecoder().decode(WallpaperPrefs.self, from: json)
        XCTAssertEqual(p.speed, 2.0)
        XCTAssertEqual(p.volume, 1)
    }

    func testPrefsRoundTripThroughASecondStore() {
        let a = WallpaperPrefsStore(defaults: defaults)
        let item = UUID()
        var p = a.prefs
        p.pauseOnBattery = false
        p.muted = false
        p.scaling = .fit
        p.speed = 1.5
        p.assignments.defaultItem = item
        p.assignments.setChoice(.none, forDisplay: "D1")
        a.prefs = p
        let b = WallpaperPrefsStore(defaults: defaults)
        XCTAssertEqual(b.prefs, p)
    }

    func testCorruptJSONGivesDefaults() {
        defaults.set(Data("not json".utf8), forKey: "anode.wallpaper.prefs.v1")
        XCTAssertEqual(WallpaperPrefsStore(defaults: defaults).prefs, WallpaperPrefs())
    }

    func testDidChangeFiresOncePerRealChange() {
        let store = WallpaperPrefsStore(defaults: defaults)
        var fired = 0
        let token = NotificationCenter.default.addObserver(forName: WallpaperPrefsStore.didChange, object: store, queue: nil) { _ in fired += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        var p = store.prefs
        p.muted = false
        store.prefs = p
        store.prefs = p
        XCTAssertEqual(fired, 1)
        p.muted = true
        store.prefs = p
        XCTAssertEqual(fired, 2)
    }

    // MARK: assignments

    func testResolvedIsTheDisplaysOwnItemElseTheDefaultElseNil() {
        var a = WallpaperAssignments()
        XCTAssertNil(a.resolved(forDisplay: "D1"))
        let def = UUID(), own = UUID()
        a.defaultItem = def
        XCTAssertEqual(a.resolved(forDisplay: "D1"), def)
        a.setChoice(.item(own), forDisplay: "D1")
        XCTAssertEqual(a.resolved(forDisplay: "D1"), own)
        XCTAssertEqual(a.resolved(forDisplay: "D2"), def)
    }

    func testNoneBeatsTheDefaultAndInheritFallsBackToIt() {
        var a = WallpaperAssignments()
        let def = UUID()
        a.defaultItem = def
        a.setChoice(.none, forDisplay: "D1")
        XCTAssertNil(a.resolved(forDisplay: "D1"))
        a.setChoice(.inherit, forDisplay: "D1")
        XCTAssertEqual(a.resolved(forDisplay: "D1"), def)
        XCTAssertNil(a.perDisplay["D1"], "inherit is the absence of a choice, not a stored one")
    }

    func testRemoveItemClearsEveryReferenceToItAndNothingElse() {
        var a = WallpaperAssignments()
        let gone = UUID(), kept = UUID()
        a.defaultItem = gone
        a.setChoice(.item(gone), forDisplay: "D1")
        a.setChoice(.item(kept), forDisplay: "D2")
        a.setChoice(.none, forDisplay: "D3")
        a.removeItem(gone)
        XCTAssertNil(a.defaultItem)
        XCTAssertNil(a.perDisplay["D1"], "a display that pointed at the removed item goes back to the default")
        XCTAssertEqual(a.perDisplay["D2"], .item(kept))
        XCTAssertEqual(a.perDisplay["D3"], DisplayChoice.none)
    }

    func testAssignmentsRoundTripThroughJSON() throws {
        var a = WallpaperAssignments()
        a.defaultItem = UUID()
        a.setChoice(.item(UUID()), forDisplay: "D1")
        a.setChoice(.none, forDisplay: "D2")
        let back = try JSONDecoder().decode(WallpaperAssignments.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(back, a)
    }

    func testYouTubeQualityDefaultsToTheBestAndKeepsTheChosenOneAcrossAReload() throws {
        XCTAssertEqual(WallpaperPrefs().youtubeQuality, .p2160)
        XCTAssertEqual(YouTubeQuality.allCases.map(\.height), [2160, 1440, 1080, 720], "the four the owner asked for, best first")
        var p = WallpaperPrefs(); p.youtubeQuality = .p1080
        let back = try JSONDecoder().decode(WallpaperPrefs.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back.youtubeQuality, .p1080)
    }

    func testAnOlderValueWithNoQualityOrAnUnknownOneReadsAsTheDefault() throws {
        XCTAssertEqual(try JSONDecoder().decode(WallpaperPrefs.self, from: Data(#"{"speed": 1}"#.utf8)).youtubeQuality, .p2160)
        XCTAssertEqual(try JSONDecoder().decode(WallpaperPrefs.self, from: Data(#"{"youtubeQuality": 4320}"#.utf8)).youtubeQuality, .p2160)
    }
}
