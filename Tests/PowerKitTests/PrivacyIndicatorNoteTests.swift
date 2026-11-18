import XCTest
@testable import PowerKit
@testable import AnodeApp

/// macOS 27.3's privacy indicator says "Accessing all apps" for an app that holds an event tap (it watches the keyboard or the
/// mouse); reading other apps through Accessibility is named app by app. Anode holds taps for its shortcuts, switchers and icon
/// clicks, so each feature that does says so in Beta Features, with the true reason (it used to blame Accessibility).
final class PrivacyIndicatorNoteTests: XCTestCase {

    // ── The sentence ────────────────────────────────────────────────────────

    func testTheSentenceNamesTheWordingTheConditionAndWhatIsWatched() {
        let text = PrivacyIndicatorNote.text(while: "this is on", watching: "the keyboard for its shortcut")
        XCTAssertTrue(text.hasPrefix("While this is on, "))
        XCTAssertTrue(text.contains("macOS 27.3 and later"))
        XCTAssertTrue(text.contains("\u{201C}Accessing all apps\u{201D}"))
        XCTAssertTrue(text.contains("because Anode watches the keyboard for its shortcut"))
    }

    func testTheSentenceSaysMacOSWordsItThatWayForAnyApp() {
        // So the person does not read it as something Anode does beyond the feature.
        XCTAssertTrue(PrivacyIndicatorNote.text(while: "x", watching: "y").contains("any app that does"))
    }

    func testTheSentenceDoesNotBlameAccessibility() {
        // Reading another app through Accessibility shows that app's name ("Accessing Dock"), never "all apps".
        XCTAssertFalse(PrivacyIndicatorNote.text(while: "x", watching: "y").contains("Accessibility"))
    }

    // ── Which features say it ───────────────────────────────────────────────

    private func summaries() throws -> [(name: String, summary: String)] {
        let (defaults, suite) = try TestDefaults.make(owner: "PrivacyIndicatorNote", test: name)
        defer { TestDefaults.destroy(defaults, suite) }
        let s = Settings(defaults: defaults)
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PIN-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        return [
            ("Window Switcher", WindowSwitcherFeature(settings: s).summary),
            ("Desktop Switcher", DesktopSwitcherFeature(settings: s).summary),
            ("Window Actions", WindowActionsFeature(settings: s).summary),
            ("Window Groups", WindowGroupsFeature(settings: s, controller: { nil }).summary),
            ("Sound Menu", SoundMenuFeature(settings: s).summary),
            ("Battery Menu", BatteryMenuFeature(settings: s).summary),
            ("Ultra Low Power Mode", UltraLowPowerFeature(settings: s).summary),
            ("Live Wallpapers", LiveWallpaperFeature(settings: s, library: WallpaperLibrary(directory: dir),
                                                     prefsStore: WallpaperPrefsStore(defaults: defaults),
                                                     store: ShortcutStore(defaults: defaults), displays: { [] },
                                                     controller: { nil }, importer: nil).summary),
            ("Menu Bar Hider", MenuBarHiderFeature(settings: s, items: { [] }, accessibilityAllowed: { true },
                                                   screenRecordingAllowed: { true }, status: { nil }).summary),
            ("Keyboard & Screen Cleaner", KeyboardCleanerFeature(settings: s, store: ShortcutStore(defaults: defaults),
                                                                cleaner: { nil }, accessibilityAllowed: { true },
                                                                requestAccessibility: {}).summary),
        ]
    }

    func testEveryFeatureThatHoldsATapSaysItWillShowAsAllApps() throws {
        for (name, summary) in try summaries() {
            XCTAssertTrue(summary.contains("\u{201C}Accessing all apps\u{201D}"), "\(name) holds an event tap and does not say what macOS will show")
            XCTAssertTrue(summary.contains("because Anode watches"), "\(name) does not say why")
        }
    }

    func testNoFeatureBlamesAccessibilityForTheWording() throws {
        for (name, summary) in try summaries() {
            XCTAssertFalse(summary.contains("macOS's own wording for Accessibility"), "\(name) still blames Accessibility")
        }
    }

    func testTheSoundMenuNoteIsAboutMacOSsOwnIconBecauseOnlyThatHoldsATap() throws {
        let sound = try summaries().first { $0.name == "Sound Menu" }!.summary
        XCTAssertTrue(sound.contains("While the option to open it from macOS's own Sound icon is on, "))
    }

    // ── The welcome ─────────────────────────────────────────────────────────

    func testTheWelcomeTiesTheWordingToWatchingTheKeyboardAndMouseNotToAccessibility() {
        let said = FirstRunWelcome.text
        XCTAssertTrue(said.contains("Accessing all apps"))
        XCTAssertTrue(said.contains("keyboard and mouse"))
        XCTAssertFalse(said.contains("to read and press things in other apps. macOS 27.3"), "the welcome still ties it to Accessibility")
    }

    // ── A new tap has to be accounted for ───────────────────────────────────

    private func swiftFiles(in directory: String, containing needle: String) throws -> Set<String> {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent(directory)
        var found = Set<String>()
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".swift") {
            let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            if text.contains(needle) { found.insert(name) }
        }
        return found
    }

    func testEveryFileThatCreatesAnEventTapIsKnown() throws {
        // A file added to this list needs its feature's summary to carry PrivacyIndicatorNote (the tests above), or a reason here.
        let known: Set<String> = [
            "CleanerInputTap.swift",       // Keyboard & Screen Cleaner: only while the screen is black
            "MediaKeyTap.swift",           // the volume keys: only while Anode's Sound menu is open
            "WindowDragSnapping.swift",    // Window Actions
            "NativeMenuExtraIcon.swift",   // Sound Menu (macOS's own icon), Battery Menu
            "Shortcuts.swift",             // one tap for every shortcut owner, listed below
            "DesktopSwitcher.swift",       // Desktop Switcher
            "WindowSwitcher.swift",        // Window Switcher
        ]
        XCTAssertEqual(try swiftFiles(in: "Sources/AnodeApp", containing: "CGEvent.tapCreate("), known,
                       "an event tap was added or removed: macOS shows \u{201C}Accessing all apps\u{201D} for it, so say so in that feature's summary")
    }

    func testEveryShortcutOwnerIsKnown() throws {
        let known: Set<String> = [
            "WindowSnapping.swift",         // Window Actions
            "WindowGroups.swift",          // Window Groups
            "LiveWallpaperRuntime.swift",  // Live Wallpapers
            "MenuBarHiderRuntime.swift",   // Menu Bar Hider
            "UltraLowPowerRuntime.swift",  // Ultra Low Power Mode
            "KeyboardCleaner.swift",       // Keyboard & Screen Cleaner: its key to end it, only while the screen is black
        ]
        XCTAssertEqual(try swiftFiles(in: "Sources/AnodeApp", containing: "KeybindCenter.shared.register("), known,
                       "a feature now registers a shortcut, which keeps the shared keyboard tap on: say so in its summary")
    }
}
