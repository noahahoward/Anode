# Live Wallpapers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Beta Features section where the user adds videos, images, HTML pages (a file, a folder, or a URL) and links to videos to a library and assigns one to each display (or one to all) as the desktop wallpaper, costing almost nothing when nobody can see it, with every feature free.

**Architecture:** One borderless window per display, placed at the desktop-window level (above the system wallpaper, below desktop icons and widgets), showing an `AVPlayerLayer` (video), a layer with a downsampled image (image) or a `WKWebView` (web). A pure policy decides per display whether it should be running (battery, Low Power Mode, heat, display asleep, locked, covered by windows, a full-screen app, the user's own pause). A controller maps displays to library items, shares one player between displays showing the same video, and reacts only to events (no polling). An optional **tiled mode** splits a video into a grid of pre-cut tile files, one tiny window and player per square, so only squares that are actually visible decode. The model, library, policy and controller are pure/injected and unit-tested; the windows, players and web views are a thin real layer verified on the Mac. **Task 1 is a measured go/no-go with the owner present, and Task 9 (tiles) is gated on measurements from it.**

**Tech Stack:** Swift 5.9, AppKit, AVFoundation, ImageIO, WebKit (`WKWebView`), Network (`NWPathMonitor`), VideoToolbox (`VTIsHardwareDecodeSupported`), IOKit power-source notifications, XCTest (`Tests/PowerKitTests`).

**Spec:** the owner's briefs of 2026-11-06: "live desktop wallpapers… many apps have done this but lock it behind a paywall or don't have full features, so we're going to build our own", then "html files or URLs to videos as wallpapers, those are VERY handy, or even just png for normal wallpaper", then "divide the wallpaper into a grid of small squares and play a square only when it is visible". Competing apps are reference for behaviour only; no code is copied. Decisions beyond the briefs are marked *(author's call)*.

## Global Constraints

- Beta Features section "Live Wallpapers", **off by default** (`liveWallpaperEnabled`). While off: no windows, players, web views, observers or timers.
- **Content kinds** (`WallpaperKind`): `video`, `image`, `web`. Ways in: **Add file…** (a video, an image, or one `.html` file), **Add folder…** (a web wallpaper: a folder with `index.html` at its root), **Add link…** (a URL). Links are classified by `WallpaperURLClassifier`: a direct video link (`.mp4 .mov .m4v .m3u8`) is **downloaded into the library by default** with an opt-in "stream instead"; a direct image link is downloaded; a YouTube link becomes the official embed player page (autoplay, muted, loop, no controls); anything else is a live web page. **https only** *(author's call)*. Downloads show progress, can be cancelled, and refuse anything over 2 GB. No video-site downloading tools are used.
- Images: PNG, JPEG, HEIC, TIFF, WebP, GIF (first frame). Drawn from a copy downsampled with ImageIO to the display's pixel size, so a 100-megapixel photo costs one screen's worth of memory. An image never plays or pauses and costs nothing at runtime.
- Web content runs in `WKWebView` with: a **non-persistent** data store, JavaScript on, `javaScriptCanOpenWindowsAutomatically = false`, autoplay allowed (`mediaTypesRequiringUserActionForPlayback = []`), a document-start user script that forces every media element muted (unless the user unmuted), main-frame navigation away from the loaded page cancelled, and local pages loaded with `loadFileURL(_:allowingReadAccessTo:)` limited to their own folder. The window is click-through, so there is no interaction. A page that fails to load makes that display fall back to the system wallpaper and reloads when the network returns (`NWPathMonitor`, created only while a remote page is showing).
- **Add folder…** refuses a folder without a root `index.html`, one over 500 MB or 5000 files, and never copies a folder the user did not pick (no "copy the file's siblings" shortcut: a page picked from Downloads must not drag Downloads along).
- Window per display: borderless `NSWindow`, level `NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))`. **Measured 2026-11-06 on this Mac (macOS 27):** the system's own "Wallpaper" window (owner WindowManager) is at layer −2147483624; `.desktopWindow` is −2147483623, one above it; Finder's desktop layer and the "Event Shield Window" are at −2147483603; desktop widgets at −2147483601. Task 1 re-checks this with our window in the list.
- Window flags: `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]`, `ignoresMouseEvents = true`, `animationBehavior = .none`, `hasShadow = false`, opaque black background, `canBecomeKey` and `canBecomeMain` false, frame exactly the display's `frame`.
- Displays are identified by **display UUID** (`CGDisplayCreateUUIDFromDisplayID`), never by index; assignments survive unplugging and replugging a monitor.
- Library: local files are **copied** into `~/Library/Application Support/Anode/Wallpapers/` (APFS makes a copy a free clone; Task 1 measures it), with `library.json` and one poster (PNG) and one thumbnail (JPEG) per item. Files are deleted only by an explicit Remove.
- Video accepted: anything `AVURLAsset` reports playable with a video track (MP4, MOV, M4V, HLS; H.264, HEVC, ProRes). Codecs without hardware decode (`VTIsHardwareDecodeSupported` false) are **allowed with a visible warning** "uses software decoding, costs more battery" *(author's call)*.
- Defaults *(author's call)*: **muted**, volume 0.5 when unmuted, scaling **fill** (videos and images; web pages always fill the display), speed **1.0** (videos, range 0.25–2), pause **on battery**, **in Low Power Mode**, **when hot** (`ProcessInfo.thermalState` serious or critical), **when fully covered** (after 0.5 s; resumes at once), **when a full-screen app is up**. Display asleep and screen locked always pause. A user pause always wins. Pausing a web page = suspend media, dispatch an `anode-pause` event to the page, and take the web view out of the window so WebKit marks it hidden; resuming reverses it (Task 1 measures that this really stops the CPU).
- Player quality: `preferredMaximumResolution` = the display's pixel size; one `AVQueuePlayer` + `AVPlayerLooper` per *item*, shared by every display showing it.
- Shortcut command `wallpaper.pause` (pause / resume), default **⌃⌥⌘W** *(author's call)*, through `ShortcutStore`/`KeybindCenter`.
- Needs **no permission**: not Screen Recording, not Accessibility. Network is used only by link items.
- The menu bar's text colour is chosen by macOS from the *real* wallpaper, not from any window (measured 2026-10-22). This plan does not fix that by itself; the optional match setting (Task 8) and the existing menu bar backdrop do. The section says so.
- Package target stays macOS 13. New branch `live-wallpapers` off `main`; never commit to `main`. Test command: `swift test --filter <TestClass>`.
- The owner is using the Mac: automated tests never show a window on screen, play a video, or touch the network (downloads and snapshots are injected). The real thing is exercised in Tasks 1 and 10, when the owner says so.
- Last step: `./build-app.sh`, confirm `BSSourceCommit` equals `git rev-parse --short HEAD` and the running process's inode matches the installed binary.

## Review Focus

- A window fully covers the desktop, then moves so a sliver shows, then goes away: pauses 0.5 s after full cover, any uncovering resumes at once, no flapping when a window is dragged across. (Tasks 3, 6)
- Display sleep/wake, lock/unlock, a monitor unplugged and replugged, a Space change: never a black or empty desktop, no window, player or web view left behind, and when anything fails the system wallpaper simply shows through. (Task 6)
- The source file deleted, moved or unplayable; a link that goes dead, redirects to http, or serves something that is not what its extension said; a web page that throws errors or navigates away: no crash, the row says what is wrong, the desktop falls back, other displays carry on. (Tasks 4, 5, 6, 7)
- Charger unplugged mid-play, Low Power Mode toggled, heat rising: pauses within seconds, resumes when the condition clears, and the user's own pause survives all of it. (Tasks 3, 6)
- Feature turned off, or the playing item removed from the library: windows close, players and web views are released (memory falls back), assignments to the removed item are cleared, no file is deleted by anything but Remove. (Tasks 2, 6)
- A hostile or sloppy web wallpaper (opens windows, autoplays loud audio, redirects, reads local files, loops forever at 100 % CPU): contained by the web constraints above and stopped by the pause rules. (Task 5)

## File Structure

| File | Responsibility |
|---|---|
| `Sources/PowerKit/Settings.swift` (modify) | `liveWallpaperEnabled` |
| `Sources/PowerKit/WallpaperPrefs.swift` (create) | `WallpaperScaling`, `DisplayChoice`, `WallpaperAssignments`, `WallpaperPrefs`, `WallpaperPrefsStore` |
| `Sources/PowerKit/WallpaperLibrary.swift` (create) | `WallpaperKind`, `WallpaperSource`, `TileSet`, `WallpaperItem`, `WallpaperLibrary` (index + files) |
| `Sources/PowerKit/WallpaperPolicy.swift` (create) | pause reasons, `WallpaperPolicy`, `PauseGate`, `RefCountedPool` |
| `Sources/PowerKit/WallpaperURLClassifier.swift` (create) | link classification, YouTube embed URL |
| `Sources/AnodeApp/WallpaperImporter.swift` (create) | video / image / HTML file / web folder / web page import, posters, thumbnails |
| `Sources/AnodeApp/WallpaperDownloader.swift` (create) | https download with progress, cancel and size cap |
| `Sources/AnodeApp/WallpaperSurface.swift` (create) | `DisplayInfo`, `WallpaperSurface` protocols, the desktop window, `WallpaperPlayers` |
| `Sources/AnodeApp/VideoWallpaperSurface.swift`, `ImageWallpaperSurface.swift`, `WebWallpaperSurface.swift` (create) | the three content renderers and the real factory |
| `Sources/AnodeApp/WallpaperConditionsSource.swift` (create) | the real inputs to the policy, as events |
| `Sources/AnodeApp/LiveWallpaperController.swift` (create) | displays ↔ surfaces, pause logic |
| `Sources/AnodeApp/WallpaperSystemSync.swift` (create) | optional: set the system wallpaper to the poster, back up and restore (Task 8) |
| `Sources/PowerKit/WallpaperTiles.swift`, `Sources/AnodeApp/WallpaperTiler.swift`, `Sources/AnodeApp/TiledVideoSurface.swift` (create) | tile grid maths and clock; cutting a video into tiles; the tiled renderer (Task 9) |
| `Sources/AnodeApp/Shortcuts.swift` (modify) | `ShortcutCommands.wallpaper` added to `all` |
| `Sources/AnodeApp/BetaFeaturesWindow.swift` (modify) | `LiveWallpaperFeature` section, added to the list in `init` |
| `Sources/AnodeApp/main.swift` (modify) | construct the controller beside `keepAwake` (~line 321) |
| `Tests/PowerKitTests/…` (create) | `WallpaperPrefsTests`, `WallpaperLibraryTests`, `WallpaperPolicyTests`, `WallpaperURLClassifierTests`, `WallpaperImporterTests`, `WallpaperSurfaceTests`, `LiveWallpaperControllerTests`, `WallpaperSystemSyncTests`, `WallpaperTilesTests`, `LiveWallpaperFeatureTests`, `TestVideo.swift` (writes a tiny H.264 MOV with `AVAssetWriter` into a temp folder), `TestImage.swift` |

---

### Task 1: Spike, go / no-go (owner present)

**Files:** a probe in the session scratchpad only; findings recorded in this file under "Measured".

- [ ] **Step 1: Ask the owner** for a few minutes of their desktop and a short clip to use (candidates: `~/Movies/1080p.MOV`, the `Car Short Films` or `Drone Video` folders). Do not run otherwise.
- [ ] **Step 2: Video window.** Write a probe app (scratchpad) that opens the Global Constraints window on the built-in display playing the clip muted and looping with `AVPlayerLooper`. Record with `CGWindowListCopyWindowInfo` where it sits relative to "Wallpaper" (−2147483624), Finder's layer and widgets (−2147483601). GO needs: visible, above the wallpaper, below widgets and the Event Shield.
- [ ] **Step 3: Input and stacking.** Owner clicks the desktop (click-to-reveal) and drags a Finder window over it; clicks must pass through and windows must sit above the video. Owner switches Spaces, opens Mission Control, App Exposé and Stage Manager: record whether the video stays, flashes the old wallpaper, or vanishes.
- [ ] **Step 4: Occlusion, whole window.** Log `occlusionState` changes while the owner (a) opens a window that covers half the screen, (b) maximizes one, (c) puts an app full screen, (d) minimizes everything. Record exactly when `.visible` goes false, and whether a thin visible sliver keeps it true.
- [ ] **Step 5: Lifecycle.** Let the display sleep and wake, then lock (⌃⌘Q) and unlock: does playback continue by itself, or does the player need to be told? If the owner has an external display, repeat on it and unplug/replug it.
- [ ] **Step 6: Codecs and storage.** Run `VTIsHardwareDecodeSupported` for H.264, HEVC, ProRes, AV1 and VP9. Time `FileManager.copyItem` of the clip and compare `du` before and after (APFS clone?).
- [ ] **Step 7: Video power.** For 60 s each, playing and paused, record the probe's CPU (`ps` time deltas) and its energy through Anode's own tooling (`./.build/debug/anode -w 5 -n 15` or the Battery tab), for 1080p30 and, if available, 4K30 HEVC.
- [ ] **Step 8: Web.** Add a `WKWebView` surface to the probe with the Global Constraints configuration. Load (a) a local HTML file with a `requestAnimationFrame` animation and a `<video autoplay loop>`, (b) a YouTube embed URL with `autoplay=1&mute=1&loop=1&controls=0`, (c) a plain page. Record: it renders and animates behind widgets; clicks pass through; media is silent with the user script; CPU while showing, and CPU after the pause recipe (suspend media + event + remove from window) and after `occlusionState` alone. GO needs a paused page under 0.5 % of a core. Record whether the YouTube embed plays muted and loops.
- [ ] **Step 9: Image.** Show a very large PNG/HEIC via an ImageIO downsample and record RSS before and after (target: about one screen's worth of memory).
- [ ] **Step 10: Tiles** (decides Task 9). (a) Open 12 tiny desktop-level windows in a 4×3 grid over the display; log each one's `occlusionState` while the owner moves a window across them: does each report visible/hidden for *its own* area only, and does a sliver count? (b) Cut the clip into 12 tile files with `AVAssetExportSession` and a crop `AVVideoComposition` (HEVC, key frame at most every 1 s), play all 12 in 12 players, and compare CPU/energy with the single full-frame player of step 7; then pause 9 of the 12 and compare again. (c) Pause a tile for 10 s, then resume it with `seek(to:toleranceBefore:.zero toleranceAfter:.zero)` to the shared clock position; record the time until the first correct frame and whether any seam or stale frame is visible. GO for tiles needs: per-tile occlusion works, 12 playing tiles cost at most 1.3× one full-frame player (author's call), and the resume hitch is under 100 ms.
- [ ] **Step 11: Menu bar.** Confirm the menu bar text colour still follows the system wallpaper, not our window, and note how `MenuBarBackdrop` behaves over it.
- [ ] **Step 12: System wallpaper round trip** (the premise of Task 8). Save a copy of `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`, set a poster with `NSWorkspace.setDesktopImageURL`, then restore the copy and `killall WallpaperAgent`. Record whether the result is byte-identical (`cmp`) and how long the flash lasts.
- [ ] **Step 13: Decide.** GO for the core if the windows stack correctly, clicks pass through, playback survives Space changes and sleep/wake (or can be restarted by event), the web pause recipe works, and the 1080p cost on AC is acceptable to the owner. Record which pause conditions the measurements justify as defaults, and GO / NO-GO for Task 9. If the core is NO-GO, stop and report.
- [ ] **Step 14: Record** the measurements here, correct any Global Constraint they contradict, and commit "Live wallpapers: spike results".

### Task 2: Preferences, assignments and the library

**Files:**
- Modify: `Sources/PowerKit/Settings.swift` (follow `keepAwakeEnabled` at each of its six spots)
- Create: `Sources/PowerKit/WallpaperPrefs.swift`, `Sources/PowerKit/WallpaperLibrary.swift`
- Test: `Tests/PowerKitTests/WallpaperPrefsTests.swift`, `Tests/PowerKitTests/WallpaperLibraryTests.swift`

**Interfaces:**
- Produces:
  - `settings.liveWallpaperEnabled: Bool` (default false)
  - `public enum WallpaperScaling: String, Codable, CaseIterable { case fill, fit, stretch }`
  - `public enum DisplayChoice: Codable, Equatable { case inherit, none, item(UUID) }`
  - `public struct WallpaperAssignments: Codable, Equatable { public var defaultItem: UUID?; public var perDisplay: [String: DisplayChoice]; public func resolved(forDisplay uuid: String) -> UUID?; public mutating func setChoice(_ c: DisplayChoice, forDisplay uuid: String); public mutating func removeItem(_ id: UUID) }`
  - `public struct WallpaperPrefs: Codable, Equatable { pauseOnBattery, pauseInLowPower, pauseWhenCovered, pauseWhenHot: Bool; muted: Bool; volume: Float; scaling: WallpaperScaling; speed: Double; syncSystemWallpaper: Bool; tiledPlayback: Bool; assignments: WallpaperAssignments; public static let speedRange: ClosedRange<Double> }`
  - `public final class WallpaperPrefsStore { public init(defaults: UserDefaults, key: String = "anode.wallpaper.prefs.v1"); public var prefs: WallpaperPrefs { get set }; public static let didChange: Notification.Name }`
  - `public enum WallpaperKind: String, Codable { case video, image, web }`
  - `public enum WallpaperSource: Codable, Equatable { case file(String); case folder(directory: String, entry: String); case remote(URL) }`
  - `public struct TileSet: Codable, Equatable { public let columns: Int; public let rows: Int; public let directory: String; public let filenames: [String]; public let pixelWidth: Int; public let pixelHeight: Int }`
  - `public struct WallpaperItem: Codable, Equatable, Identifiable { public let id: UUID; public var name: String; public let kind: WallpaperKind; public let source: WallpaperSource; public let posterFilename: String?; public let thumbnailFilename: String?; public let durationSeconds: Double?; public let pixelWidth: Int?; public let pixelHeight: Int?; public let codec: String?; public let hasAudio: Bool?; public let hardwareDecodable: Bool?; public let addedAt: Date; public var tiles: TileSet? }`
  - `public final class WallpaperLibrary { public init(directory: URL, fileManager: FileManager = .default); public private(set) var items: [WallpaperItem]; public func add(_ item: WallpaperItem) throws; public func remove(id: UUID) throws; public func rename(id: UUID, to name: String) throws; public func setTiles(_ tiles: TileSet?, for id: UUID) throws; public func item(id: UUID) -> WallpaperItem?; public func contentURL(_ item: WallpaperItem) -> URL? ; public func folderURL(_ item: WallpaperItem) -> URL?; public func posterURL(_ item: WallpaperItem) -> URL?; public func thumbnailURL(_ item: WallpaperItem) -> URL?; public func isMissing(_ item: WallpaperItem) -> Bool; public static var defaultDirectory: URL; public static let didChange: Notification.Name }` (`contentURL` is the file for `.file`, `<folder>/<entry>` for `.folder`, the URL itself for `.remote`)

- [ ] **Step 1: Write the failing tests.** Prefs: defaults are exactly the Global Constraints values (`tiledPlayback` false); `speed` clamps to 0.25–2, `volume` to 0–1; round trip through a second store; corrupt JSON gives defaults; `didChange` once per real change. Assignments: `resolved` is the display's own item, else the default, else nil; `.none` beats a default; `.inherit` falls to the default; `removeItem` clears the default and every per-display reference to it and leaves others. Library (temp directory): empty at first; `add` persists across a new `WallpaperLibrary` on the same folder; each `WallpaperSource` case round-trips through JSON; `remove` deletes the file / the web folder / the tiles directory, the poster and thumbnail, and the entry, but removing a `.remote` item deletes only its poster and thumbnail; `rename` rejects an empty name; `isMissing` true after the file is deleted behind the library's back and always false for `.remote`; `contentURL` per source case; a corrupt `library.json` yields an empty library and does not delete files.
- [ ] **Step 2: Run** `swift test --filter WallpaperPrefsTests` and `--filter WallpaperLibraryTests`. Expected: FAIL.
- [ ] **Step 3: Implement** all of it. The library writes `library.json` atomically.
- [ ] **Step 4: Run** both filters. Expected: PASS.
- [ ] **Step 5: Commit** "Live wallpapers: preferences, assignments and library".

### Task 3: The pause policy (pure)

**Files:**
- Create: `Sources/PowerKit/WallpaperPolicy.swift`
- Test: `Tests/PowerKitTests/WallpaperPolicyTests.swift`

**Interfaces:**
- Consumes: `WallpaperPrefs` (Task 2).
- Produces:
  - `public enum WallpaperPauseReason: Equatable { case userPaused, displaysAsleep, screenLocked, lowPowerMode, onBattery, tooHot, fullScreenApp, covered }`
  - `public struct WallpaperGlobalConditions: Equatable { public var onBattery, lowPowerMode, thermalHot, displaysAsleep, screenLocked, userPaused: Bool }`
  - `public struct WallpaperDisplayConditions: Equatable { public var covered, fullScreen: Bool }`
  - `public enum WallpaperPolicy { public static func pauseReason(prefs: WallpaperPrefs, global: WallpaperGlobalConditions, display: WallpaperDisplayConditions) -> WallpaperPauseReason? }` (priority in the order listed above)
  - `public struct PauseGate { public init(delay: TimeInterval = 0.5); public mutating func update(_ reason: WallpaperPauseReason?, now: Date) -> WallpaperPauseReason?; public func nextCheck(now: Date) -> Date? }`
  - `public final class RefCountedPool<Key: Hashable, Value> { public init(make: @escaping (Key) throws -> Value, dispose: @escaping (Value) -> Void); public func acquire(_ key: Key) throws -> Value; public func release(_ key: Key); public var liveKeys: Set<Key> { get } }`

- [ ] **Step 1: Write the failing tests.** Policy: each pref turns its own reason on and off (`pauseOnBattery` false → on-battery plays; low power, hot, covered, full screen likewise); sleep, lock and user pause apply whatever the prefs say; nothing set → nil; priority when several hold (user pause over sleep over lock over low power over battery over heat over full screen over covered). Gate: `.covered` and `.fullScreenApp` are returned only after being continuously present for the delay (`update` at t0 → nil, at t0+0.4 → nil, at t0+0.5 → the reason); any other reason is returned at once; clearing is returned at once; a reason that flickers off and on restarts the clock; `nextCheck` is the time a pending delayed reason will take effect and nil when nothing is pending. Pool: `acquire` twice makes one value, `release` once keeps it, the second release disposes it exactly once; `make` throwing leaves nothing registered; releasing an unknown key is a no-op.
- [ ] **Step 2: Run** `swift test --filter WallpaperPolicyTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** No clocks inside: `now` is always a parameter.
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Commit** "Live wallpapers: pause policy, gate and pool".

### Task 4: Getting content in

**Files:**
- Create: `Sources/PowerKit/WallpaperURLClassifier.swift`, `Sources/AnodeApp/WallpaperImporter.swift`, `Sources/AnodeApp/WallpaperDownloader.swift`, `Tests/PowerKitTests/TestVideo.swift`, `Tests/PowerKitTests/TestImage.swift`
- Test: `Tests/PowerKitTests/WallpaperURLClassifierTests.swift`, `Tests/PowerKitTests/WallpaperImporterTests.swift`

**Interfaces:**
- Consumes: `WallpaperItem`, `WallpaperSource`, `WallpaperKind`, `WallpaperLibrary` (Task 2).
- Produces:
  - `public enum LinkKind: Equatable { case directVideo, directImage, youtube(id: String), webPage, unsupported(String) }`; `public enum WallpaperURLClassifier { public static func classify(_ url: URL) -> LinkKind; public static func youtubeEmbedURL(id: String) -> URL }`
  - `struct VideoProbe: Equatable { let durationSeconds: Double; let pixelWidth: Int; let pixelHeight: Int; let codec: String; let hasAudio: Bool; let hardwareDecodable: Bool }`
  - `enum WallpaperImportError: Error, Equatable { case notPlayable, noVideoTrack, tooShort, copyFailed, notAnImage, noIndexHTML, tooLarge, notHTTPS, unsupportedLink(String), downloadFailed }`
  - `typealias PageSnapshotter = (URL, CGSize) async throws -> CGImage`
  - `struct ImportResult { let item: WallpaperItem; let warnings: [String] }`
  - `enum WallpaperImporter { static func probeVideo(_ url: URL) async throws -> VideoProbe; static func importVideo(from url: URL, into library: WallpaperLibrary, makePoster: (AVAsset, URL) async throws -> Void = WallpaperImporter.writePoster) async throws -> ImportResult; static func writePoster(_ asset: AVAsset, to url: URL) async throws; static func importImage(from url: URL, into library: WallpaperLibrary) async throws -> ImportResult; static func importHTMLFile(from url: URL, into library: WallpaperLibrary, snapshot: PageSnapshotter) async throws -> ImportResult; static func importWebFolder(from url: URL, into library: WallpaperLibrary, snapshot: PageSnapshotter) async throws -> ImportResult; static func addLink(_ url: URL, into library: WallpaperLibrary, downloadCopy: Bool, download: (URL, URL, Int64) async throws -> Void, snapshot: PageSnapshotter) async throws -> ImportResult; static func warnings(for probe: VideoProbe) -> [String] }`
  - `final class WallpaperDownloader { func download(_ url: URL, to destination: URL, maxBytes: Int64, progress: @escaping (Double) -> Void) async throws; func cancel() }`

- [ ] **Step 1: Write the failing tests.** Classifier: `https://x.com/a.mp4`, `.mov`, `.m4v`, `.m3u8` → `.directVideo`; `.png .jpg .jpeg .heic .webp .gif` → `.directImage`; `https://www.youtube.com/watch?v=dQw4w9WgXcQ`, `https://youtu.be/dQw4w9WgXcQ`, `https://www.youtube.com/embed/dQw4w9WgXcQ` and a `&t=30s` variant all → `.youtube(id: "dQw4w9WgXcQ")`; `https://example.com/page` → `.webPage`; `http://…` anything → `.unsupported("Only https links work")`; `file:///…` and `javascript:` → `.unsupported`; `youtubeEmbedURL` contains `autoplay=1`, `mute=1`, `loop=1`, `controls=0` and `playlist=<id>`. Importer, with `TestVideo.make(seconds: 1, size: 64×64)` and `TestImage`: `probeVideo` returns duration ≈ 1 ± 0.1, 64×64, codec `"avc1"`, no audio, hardware decodable; a text file named `x.mov` throws `.notPlayable`; `importVideo` leaves the copy, a decodable PNG poster and a JPEG thumbnail in the library folder and one entry named after the file; a forced poster failure removes every file it created and adds no entry; a clip under 0.5 s throws `.tooShort`; `importImage` accepts a PNG and a HEIC-less JPEG, writes a thumbnail, and throws `.notAnImage` for a text file; `importHTMLFile` copies one `.html`, snapshots it through the injected closure and warns that other files it uses will not be found; `importWebFolder` copies a folder with a root `index.html`, throws `.noIndexHTML` without one and `.tooLarge` over 500 MB or 5000 files (limits injectable); `addLink` with a YouTube URL makes a `.web` item with `.remote(embedURL)`, with a direct video and `downloadCopy: true` calls the injected `download` and imports the file, with `downloadCopy: false` makes a `.video` item with `.remote(url)` and downloads nothing, with an `http://` URL throws `.notHTTPS`; `warnings(for:)` says "software decoding" when `hardwareDecodable` is false and "larger than" when either side exceeds 7680, and is empty otherwise.
- [ ] **Step 2: Run** `swift test --filter WallpaperURLClassifierTests` and `--filter WallpaperImporterTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** Classification is by scheme, host and extension only (no network). Video: `AVURLAsset` for playability and tracks, codec from the track's format description, `VTIsHardwareDecodeSupported`, copy with `FileManager.copyItem` under a UUID-based name keeping the extension, poster at 1 s (or the midpoint of a shorter clip), thumbnail 320 px wide. Images: ImageIO, thumbnail via `CGImageSourceCreateThumbnailAtIndex`. Web items: poster and thumbnail come from the injected snapshot (the real one is `WKWebView.takeSnapshot` after the load finishes plus 2 s, written in Task 5). `WallpaperDownloader` uses `URLSession` downloads, checks `Content-Length` and the running byte count against `maxBytes` (2 GB), and rejects any redirect to a non-https URL.
- [ ] **Step 4: Run** both filters. Expected: PASS.
- [ ] **Step 5: Commit** "Live wallpapers: importers, link classifier and downloader".

### Task 5: The real windows and renderers

**Files:**
- Create: `Sources/AnodeApp/WallpaperSurface.swift`, `Sources/AnodeApp/VideoWallpaperSurface.swift`, `Sources/AnodeApp/ImageWallpaperSurface.swift`, `Sources/AnodeApp/WebWallpaperSurface.swift`
- Test: `Tests/PowerKitTests/WallpaperSurfaceTests.swift`

**Interfaces:**
- Consumes: `WallpaperItem`, `WallpaperLibrary`, `WallpaperPrefs`, `WallpaperScaling`, `RefCountedPool` (Tasks 2, 3).
- Produces:
  - `struct DisplayInfo: Equatable { let uuid: String; let name: String; let frame: NSRect; let pixelSize: CGSize; static func current() -> [DisplayInfo] }`
  - `protocol WallpaperSurface: AnyObject { var displayUUID: String { get }; var pausable: Bool { get }; var onCoveredChange: ((Bool) -> Void)? { get set }; var onFailure: ((String) -> Void)? { get set }; func setPlaying(_ playing: Bool); func apply(_ prefs: WallpaperPrefs); func updateFrame(_ frame: NSRect); func close() }`
  - `protocol WallpaperSurfaceFactory: AnyObject { func makeSurface(for display: DisplayInfo, item: WallpaperItem, library: WallpaperLibrary, prefs: WallpaperPrefs) throws -> WallpaperSurface }`
  - `final class DesktopWallpaperWindow: NSWindow` (the Global Constraints window; `static func level() -> NSWindow.Level`)
  - `final class WallpaperPlayers` (a `RefCountedPool<UUID, AVQueuePlayer>` plus the looper kept alive per item)
  - `final class VideoWallpaperSurface`, `ImageWallpaperSurface`, `WebWallpaperSurface`, `final class RealWallpaperSurfaceFactory: WallpaperSurfaceFactory`
  - `static func gravity(for scaling: WallpaperScaling) -> AVLayerVideoGravity` on `VideoWallpaperSurface`; `static func webConfiguration() -> WKWebViewConfiguration` and `static func mutingUserScript() -> WKUserScript` on `WebWallpaperSurface`; `static func snapshot(_ url: URL, size: CGSize) async throws -> CGImage` (the real `PageSnapshotter`)

- [ ] **Step 1: Write the failing tests** (nothing is ordered front, no video plays, no network): the window's frame equals the display frame; `level.rawValue == Int(CGWindowLevelForKey(.desktopWindow))`; `collectionBehavior` contains `.canJoinAllSpaces`, `.stationary`, `.ignoresCycle`; `ignoresMouseEvents`, `!canBecomeKey`, `!canBecomeMain`, `animationBehavior == .none`; the gravity mapping for all three modes; with a `TestVideo` two surfaces for the same item acquire one player (pool `liveKeys.count == 1`) and closing both empties it; `apply(prefs)` sets `isMuted`, `volume` and the player's `defaultRate`; a missing file makes the factory throw rather than create a window; the image surface holds a bitmap no larger than the display's pixel size for a `TestImage` larger than it, and `pausable == false`; `webConfiguration()` has a non-persistent data store, `mediaTypesRequiringUserActionForPlayback` empty, `javaScriptCanOpenWindowsAutomatically == false`; the muting script is injected at document start in all frames; the web surface's navigation policy allows the first load and cancels a later main-frame navigation to another URL but allows sub-frame loads; a `.folder` item loads with read access limited to its own folder; `pausable == true` for video and web.
- [ ] **Step 2: Run** `swift test --filter WallpaperSurfaceTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** Video: `AVQueuePlayer` + `AVPlayerLooper(player:templateItem:)`, `preferredMaximumResolution` from the largest display using the item, content view layer-backed with an `AVPlayerLayer`; an `.remote` video streams the URL. Image: downsample with `CGImageSourceCreateThumbnailAtIndex` (`kCGImageSourceThumbnailMaxPixelSize` = the display's larger pixel side, transform applied) off the main thread, set as the layer's `contents` with `contentsGravity` from the scaling. Web: the Global Constraints configuration; pause recipe = `setAllMediaPlaybackSuspended(true)`, `evaluateJavaScript("window.dispatchEvent(new Event('anode-pause'))")` and `removeFromSuperview`, resume reverses it with `anode-resume`; `didFail`/`didFailProvisionalNavigation` call `onFailure` and, for remote pages, an `NWPathMonitor` (alive only while that surface exists) reloads once the path is satisfied. `onCoveredChange` fires from `NSWindow.didChangeOcclusionStateNotification` with `!occlusionState.contains(.visible)` (or the rule Task 1 found). `orderFrontRegardless` only after the first frame, image or load is ready.
- [ ] **Step 4: Run** the same command. Expected: PASS. `swift build` clean.
- [ ] **Step 5: Commit** "Live wallpapers: windows and renderers".

### Task 6: The controller and the real condition inputs

**Files:**
- Create: `Sources/AnodeApp/LiveWallpaperController.swift`, `Sources/AnodeApp/WallpaperConditionsSource.swift`
- Test: `Tests/PowerKitTests/LiveWallpaperControllerTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 2–5.
- Produces:
  - `final class LiveWallpaperController { static weak var current: LiveWallpaperController?; init(settings: Settings, library: WallpaperLibrary, prefsStore: WallpaperPrefsStore, displays: @escaping () -> [DisplayInfo], factory: WallpaperSurfaceFactory, conditions: @escaping () -> WallpaperGlobalConditions, fullScreen: @escaping (DisplayInfo) -> Bool, now: @escaping () -> Date); func reconcile(); func conditionsChanged(); func gateTimerFired(); var userPaused: Bool { get set }; func toggleUserPaused(); func reload(displayUUID: String); func shutdown(); func status(forDisplay uuid: String) -> WallpaperStatus; var onChange: (() -> Void)? }`
  - `enum WallpaperStatus: Equatable { case noWallpaper, showing(itemName: String), playing(itemName: String), paused(WallpaperPauseReason, itemName: String), failed(String) }` (`showing` for a non-pausable surface)
  - `final class WallpaperConditionsSource { init(onChange: @escaping () -> Void); func current() -> WallpaperGlobalConditions; func start(); func stop(); static func isHot(_ state: ProcessInfo.ThermalState) -> Bool }` — event-driven only: `IOPSNotificationCreateRunLoopSource`, `NSProcessInfoPowerStateDidChange`, `ProcessInfo.thermalStateDidChangeNotification`, `NSWorkspace.screensDidSleep/DidWake`, `com.apple.screenIsLocked/Unlocked` (distributed), `NSApplication.didChangeScreenParametersNotification`, `NSWorkspace.activeSpaceDidChangeNotification`.

- [ ] **Step 1: Write the failing tests** with a fake factory/surface (records `setPlaying`, `apply`, `close`; a flag for `pausable`) and a controllable clock and conditions:
  - `testOffMeansNoSurfaces`; `testOnCreatesOneSurfacePerAssignedDisplay` (a display resolved to nil gets none).
  - `testDefaultAndPerDisplayOverrideAndNone`.
  - `testChangingOneDisplaysAssignmentReplacesOnlyThatSurface`.
  - `testRemovingTheItemFromTheLibraryClosesItsSurfacesAndClearsAssignments`.
  - `testMissingFileIsReportedAndOthersCarryOn` (`status` is `.failed`, the other display still plays).
  - `testFactoryFailureIsRecordedAndNotRetriedWithoutATrigger`; `testSurfaceOnFailureFallsBackAndIsReported`; `testReloadRetriesAFailedDisplay`.
  - `testDisplayAddedOrRemovedReconciles`; `testReplugKeepsTheAssignmentByUUID`.
  - `testOnBatteryPausesAndACResumes` (with `pauseOnBattery` true), `testPrefOffKeepsPlaying`.
  - `testImageSurfaceIsNeverPausedAndReportsShowing`.
  - `testCoveredPausesOnlyAfterHalfASecond` (cover at t0; `gateTimerFired()` at +0.4 → still playing, at +0.5 → paused; uncover → playing at once).
  - `testUserPauseSurvivesConditionsClearing`.
  - `testPrefsChangeIsAppliedToEverySurfaceWithoutRecreatingThem`.
  - `testDisablingAndShutdownCloseEverySurfaceExactlyOnce`.
  - `testStatusFollowsTheState`.
  - `testIsHotIsTrueForSeriousAndCriticalOnly`.
- [ ] **Step 2: Run** `swift test --filter LiveWallpaperControllerTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** Main thread throughout. One `PauseGate` per display; one single-shot timer scheduled from `gate.nextCheck`, cancelled when nothing is pending. `reconcile()` diffs desired (display uuid → item) against live surfaces. The controller observes `Settings.liveWallpaperEnabled`, `WallpaperPrefsStore.didChange`, `WallpaperLibrary.didChange`. `WallpaperConditionsSource` is not unit-tested beyond `isHot`; Task 10 exercises it.
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Commit** "Live wallpapers: controller and condition inputs".

### Task 7: Shortcut, Beta Features section and wiring

**Files:**
- Modify: `Sources/AnodeApp/Shortcuts.swift`, `Sources/AnodeApp/BetaFeaturesWindow.swift`, `Sources/AnodeApp/main.swift`
- Test: extend `Tests/PowerKitTests/ShortcutsTests.swift`; create `Tests/PowerKitTests/LiveWallpaperFeatureTests.swift`

**Interfaces:**
- Consumes: `LiveWallpaperController.current`, `WallpaperLibrary`, `WallpaperPrefsStore`, `WallpaperImporter`, `DisplayInfo.current()`.
- Produces: `ShortcutCommands.wallpaperPause` (id `"wallpaper.pause"`, section `"Live wallpapers"`, ⌃⌥⌘W) and `ShortcutCommands.wallpaper` (in `all`); `final class LiveWallpaperFeature: BetaFeature` with `enableCheckbox`, `addFileButton`, `addFolderButton`, `addLinkButton`, `pauseButton`, `libraryStack`, `displayRows`, `scalingPopUp`, `speedSlider`, `muteCheckbox`, `volumeSlider`, one checkbox per pause rule (`batteryCheckbox`, `lowPowerCheckbox`, `coveredCheckbox`, `hotCheckbox`); `init(... importer: LiveWallpaperImporting)` where `protocol LiveWallpaperImporting { func addFile(_ url: URL) async throws -> ImportResult; func addFolder(_ url: URL) async throws -> ImportResult; func addLink(_ url: URL, downloadCopy: Bool, progress: @escaping (Double) -> Void) async throws -> ImportResult }` so tests inject it.

- [ ] **Step 1: Write the failing tests.** Shortcuts: the default label is `"⌃⌥⌘W"`; all default shortcuts across `ShortcutCommands.all` stay pairwise distinct. Feature: the checkbox writes `liveWallpaperEnabled`; Add file runs the injected importer for a video, an image and an `.html` file alike (it only dispatches by extension) and a new library row appears with its warnings visible; Add folder and Add link likewise; the link sheet offers "Download a copy (recommended)" on and a refusal message for an `http://` link; each connected display (injected `[DisplayInfo]`) has a popup listing "Same as default", "None" and every library item, and choosing one writes the assignment; the pause rule checkboxes and the mute/volume/scaling/speed controls write `WallpaperPrefs`, with speed and mute disabled when no assigned item is a video or web page; a `.failed` status shows its text with a Reload button, and a missing-file item shows "File missing" with a Remove button; Remove deletes (it is the explicit action); Pause/Resume toggles `userPaused` and its title follows; while off, everything but the checkbox is hidden.
- [ ] **Step 2: Run** `swift test --filter ShortcutsTests` and `--filter LiveWallpaperFeatureTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** Summary text: "Use a video, an image, a web page or a link to a video as your desktop wallpaper, on any display. Pauses itself on battery, in Low Power Mode, when hot, when windows cover the desktop, and when a full-screen app is up. macOS still picks the menu bar's text colour from your real wallpaper, so pick a dark wallpaper or use the menu bar backdrop." Add file/folder via `NSOpenPanel` (movie, image and html types; directories for the folder button). Register the pause shortcut with `KeybindCenter` only while the feature is on. Construct the controller, library, store and `WallpaperConditionsSource` in `main.swift` beside `keepAwake`; call `shutdown()` on terminate.
- [ ] **Step 4: Run** both filters plus `swift test --filter BetaLayoutTests`. Expected: PASS.
- [ ] **Step 5: Commit** "Live wallpapers: Beta Features section".

### Task 8: Optional — match the system wallpaper (menu bar text and first-frame continuity)

**Files:**
- Create: `Sources/AnodeApp/WallpaperSystemSync.swift`
- Modify: `Sources/AnodeApp/LiveWallpaperController.swift` (call the sync when `prefs.syncSystemWallpaper` and surfaces change), `Sources/AnodeApp/BetaFeaturesWindow.swift` (one checkbox)
- Test: `Tests/PowerKitTests/WallpaperSystemSyncTests.swift`

**Interfaces:**
- Produces:
  - `protocol SystemWallpaperAPI: AnyObject { func readIndex() -> Data?; func writeIndex(_ data: Data) -> Bool; func setDesktopImage(_ url: URL, displayUUID: String) -> Bool; func restartWallpaperAgent() }`
  - `final class WallpaperSystemSync { init(api: SystemWallpaperAPI, backupDirectory: URL, defaults: UserDefaults); func adopt(posters: [String: URL]); func restoreOriginal(); func recoverAtLaunch(syncStillWanted: Bool) }`

- [ ] **Step 1: Write the failing tests** with a fake API: the first `adopt` backs up the index before touching anything and records the backup path in `anode.wallpaper.systemBackup`; a second `adopt` never overwrites that backup; `setDesktopImage` is called once per display that has a poster and never for a display without one; `restoreOriginal` writes the backup bytes back, restarts the agent once, clears the record and deletes nothing else; with no backup it does nothing (never invents one); `recoverAtLaunch(syncStillWanted: false)` restores when a record exists, `true` keeps it and restores nothing; an unreadable index means `adopt` changes nothing and reports failure.
- [ ] **Step 2: Run** `swift test --filter WallpaperSystemSyncTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** Off by default and clearly worded: "Also sets each wallpaper's first frame as your Mac's wallpaper while this is on, so the menu bar text matches and there is no jump at wake or login. Anode puts your original wallpaper settings back when you turn this off." The real API is `NSWorkspace.setDesktopImageURL(_:for:options:)`, a byte copy of `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist` and `killall WallpaperAgent` through `Process`. Quitting Anode while sync is on leaves the poster in place; turning the feature or the setting off restores the original at once; a launch that finds a record and the feature off restores it (crash recovery, the pattern of the Dock hold).
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Commit** "Live wallpapers: optional system wallpaper match".

### Task 9: Tiled playback — only the visible squares decode (gated on Task 1 step 10)

Do this task **only if Task 1 recorded GO for tiles**; otherwise record "dropped: <measurement>" here and tell the owner.

Why it is built this way: a hardware video decoder produces whole frames, so drawing only part of a frame saves nothing. The saving comes from cutting the video into a grid of separate tile videos at import, with one small window and player per square. The window server then reports each square's visibility itself (`occlusionState`), event-driven, and a hidden square's player is paused. Images and web pages do not tile (an image costs nothing; a page pauses as a whole).

**Files:**
- Create: `Sources/PowerKit/WallpaperTiles.swift`, `Sources/AnodeApp/WallpaperTiler.swift`, `Sources/AnodeApp/TiledVideoSurface.swift`
- Modify: `Sources/AnodeApp/WallpaperSurface.swift` (`RealWallpaperSurfaceFactory` picks the tiled surface), `Sources/AnodeApp/BetaFeaturesWindow.swift` (per-row "Prepare tiles", progress, "Remove tiles", and the `tiledPlayback` checkbox)
- Test: `Tests/PowerKitTests/WallpaperTilesTests.swift`

**Interfaces:**
- Consumes: `TileSet`, `WallpaperItem`, `WallpaperLibrary.setTiles` (Task 2), `WallpaperSurface` (Task 5), `PauseGate` (Task 3).
- Produces:
  - `public struct TileGrid: Equatable { public let columns: Int; public let rows: Int; public static func choose(videoWidth: Int, videoHeight: Int) -> TileGrid; public func rects(in frame: CGRect) -> [CGRect] }` (row-major; integer-pixel edges, the last column and row absorb the remainder; 12 tiles for 16:10 and 16:9, bounded to 3...6 columns and 2...4 rows)
  - `public enum TileClock { public static func position(now: Double, epoch: Double, duration: Double, rate: Double) -> Double }`
  - `public enum TileMatch { public static func isCompatible(tileAspect: Double, displayAspect: Double) -> Bool }` (within 2 %)
  - `final class WallpaperTiler { func tile(video: URL, grid: TileGrid, into directory: URL, progress: @escaping (Double) -> Void) async throws -> TileSet; func cancel() }`
  - `final class TiledVideoSurface: WallpaperSurface` (one `DesktopWallpaperWindow` per tile at that tile's rect, one shared epoch, per-tile players; the surface's `onCoveredChange` reports "all tiles hidden")

- [ ] **Step 1: Write the failing tests.** `TileGrid.choose` gives 4×3 for 1920×1080 and 3840×2400, never fewer than 3 columns or more than 6; `rects(in:)` for an 1800×1169 frame tile it exactly (union equals the frame, no overlaps, no gaps, all integer edges); `TileClock.position` wraps modulo duration, honours `rate`, and is monotonic within a loop; `TileMatch` accepts 16:10 vs 1.601 and rejects 16:9 vs 16:10; a surface test with fake tile windows: hiding 9 of 12 pauses exactly those 9 and leaves 3 playing, showing one again seeks it to `TileClock.position` and plays, all hidden reports covered, and a missing tile file makes the factory fall back to the normal video surface.
- [ ] **Step 2: Run** `swift test --filter WallpaperTilesTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** The tiler exports each tile with `AVAssetExportSession` (HEVC preset) and an `AVMutableVideoComposition` whose render size is the tile size and whose layer instruction scales the source to fill the reference size then translates by the tile origin; no audio; key frames at most 1 s apart; the output goes to `<library>/<item>-tiles/` and `setTiles` records it; cancelling deletes the partial directory. `TiledVideoSurface` creates the tile windows at `grid.rects(in: display.frame)`, starts all tile players together with `setRate(_:time:atHostTime:)` from one host-time epoch, and on each resume seeks with zero tolerance to `TileClock.position`; it is used only for a display whose aspect passes `TileMatch` and only when `prefs.tiledPlayback` is on and the item has a `TileSet`.
- [ ] **Step 4: Run** the same command. Expected: PASS. `swift build` clean.
- [ ] **Step 5: Commit** "Live wallpapers: tiled playback".

### Task 10: On-hardware verification (only when the owner says so)

**Files:** none; record findings under "Measured" in this file.

- [ ] **Step 1: Build and install** (`./build-app.sh`). Owner turns the section on and adds, in turn: a video, a PNG, a single `.html` file, a web folder, a YouTube link, a direct video link (downloaded) and a plain web page. Expected: each plays or shows on the desktop, below icons and widgets, and the library shows posters and warnings.
- [ ] **Step 2: Pause rules, one at a time.** Unplug the charger (pauses within seconds; replug resumes), toggle Low Power Mode, maximize a window (pauses after ~0.5 s; restore resumes at once), full-screen an app, let the display sleep, lock the Mac, press ⌃⌥⌘W. Expected: each matches Global Constraints and none leaves a black desktop. Images stay put throughout; a web page's CPU falls to near zero while paused.
- [ ] **Step 3: Displays and Spaces.** Plug and unplug the external display; switch Spaces; open Mission Control and Stage Manager. Expected: no flash of the old wallpaper, no orphan window (compare the `CGWindowList` count of Anode windows at the desktop layer before and after).
- [ ] **Step 4: Failure.** Delete a playing clip's file in Finder; add a dead link; turn off Wi-Fi under a remote page and turn it back on; try an unplayable file and an `http://` link. Expected: each row says what is wrong, the system wallpaper shows, the page reloads when the network returns, nothing crashes.
- [ ] **Step 5: Web safety.** Load a page that calls `window.open`, one that sets `location` to another site, and one that autoplays unmuted audio. Expected: no new window, the navigation is cancelled, the audio is silent.
- [ ] **Step 6: Teardown.** Turn the feature off; `kill -9` the app while it is on. Expected: windows vanish, memory falls (`ps` RSS), and if Task 8 is on the original wallpaper is restored on the next launch with the feature off (`cmp` the index against the saved copy).
- [ ] **Step 7: Tiles** (if Task 9 was built). Prepare tiles for a clip; with tiling on, cover part of the desktop with a window and confirm by `CGWindowList` and by CPU that only the uncovered tiles play, that a tile coming back into view shows the right frame without a visible jump or seam, and that cost with the desktop half covered is clearly below the untiled cost.
- [ ] **Step 8: Cost.** Repeat Task 1's 60 s CPU and energy measurements with the real app: playing on AC, paused by cover, paused on battery, a web page playing and paused, an image. The paused cases must read like the baseline of 0.27 % of a core with the window closed.
- [ ] **Step 9: Record** the results and commit "Live wallpapers: verified on hardware".

---

## What comes after this plan (separate plans, not started)

Each reuses the library, assignments, policy and controller; the extension point is `WallpaperKind` and the `WallpaperSurfaceFactory` protocol.

- **Playlists and schedules:** rotate through several items, change by time of day, by light/dark appearance, by AC vs battery, and a different wallpaper per Space; image slideshows.
- **Generative and Anode-aware:** Metal shader wallpapers, wallpapers that draw live Anode data (CPU/GPU/battery graphs), and wallpapers that react to the cursor (a global mouse position feed; the window itself must stay click-through).
- **Not possible for a third-party app, so not planned:** the lock screen and login window wallpaper, and macOS screen savers as live wallpapers.

## Measured (Task 1 spike, 2026-11-06, MacBook Pro 14" Mac17,9, one built-in display, macOS 27)

Probes: `docs/superpowers/spikes/2026-11-06-live-wallpapers-probe.swift` (modes `codecs`, `video`, `web`, `cuttiles`, `tileplay`, `tiles`) and `…-act.swift` (synthetic input helper). The owner said "go control the computer"; I drove it myself, hiding other apps for 3 s and restoring them in their original stacking order, using one blank TextEdit document (closed without saving, TextEdit quit), and stepping through Spaces and back. Not done (needs the owner): Steps 5 (display sleep/wake, lock/unlock, external display) and 12 (system wallpaper round trip: it would change the owner's real wallpaper).

**Step 2 — window and stacking: GO.** Our window at `.desktopWindow` = −2147483623, on screen, playing (rate 1.0, `readyToPlay`). Window list, bottom to top: Display Backstop −…626, Offscreen Wallpaper −…625, system "Wallpaper" −…624, **ours −…623**, Event Shield and Finder −…603, underbelly/Safe-Area shield −…602, Notification Center widgets −…601. Exactly as the plan assumed.

**Step 3 — input and stacking.**
- Click-through: with every other app hidden, a synthetic click on the bare desktop made **Finder** frontmost, so the click passed through our window.
- Spaces: playback never stalled across 8 Space switches (clock advanced every 2 s). During each slide `occlusionState.visible` goes **false for about 0.5 s** (e.g. 73.57 → 74.11 s) and is true again on arrival. **This is the same size as the plan's 0.5 s "covered" gate, so keep that gate.** A bare empty Space shows the video normally. Exactly one on-screen "Menubar" window after every switch.
- Mission Control: the video stays as the desktop behind the shrunken windows (`…-wallpaper-mission-control.png`). No flash of the old wallpaper seen in the screenshot (a single frame; the owner should still look).
- Not tested: Stage Manager, App Exposé (ran, no log change, not looked at).
- Synthetic ⌃←/⌃→ posted with CGEvent did nothing here; the same keys sent through System Events `key code … using {control down}` switched Spaces (Anode's notes said the CGEvent route worked on another day).

**Step 4 — occlusion.**
- Whole window: a maximized app (Brave at 0,39 1800×1130 plus Code windows behind) leaves the 39 pt menu-bar strip uncovered, so **`.visible` stays true with the desktop apparently "covered"**. Only a **full-screen app** (its own Space) made it go false, and it stayed false (`vis=n` for the 10+ s I let it sit) while the player kept running. **Consequence for Tasks 3 and 6: "fully covered" cannot be read from the whole window's occlusionState on a Mac with a menu bar; either compute coverage from the window list excluding the menu-bar band, or accept that only full-screen apps and Spaces pause it.**
- Per tile (Step 10a): 12 desktop-level tiles on an empty Space each report only their own area. Cover left half → exactly the 6 left tiles false. **A 6 pt sliver and a 1 pt sliver both keep a tile visible.** Whole-screen cover → all 12 false; uncover → all 12 true (≈1 s after the change in my sampling).

**Step 6 — codecs and storage.** `VTIsHardwareDecodeSupported`: H.264, HEVC, ProRes 422, AV1, **VP9 all true** (VP9 after `VTRegisterSupplementalVideoDecoderIfAvailable`). `FileManager.copyItem` of the 666 MB 1080p MOV: **0.000 s and 88 KB of free space** used → APFS clone confirmed.

**Step 7 — video power (probe CPU as `ps` cputime deltas; per-process energy was not obtainable).**

| Content | Playing | Paused |
|---|---|---|
| 1080p30 H.264 | 1.6–2.0 % of one core, RSS 62 MB | 0.05 % |
| 4K60 HEVC (16 s clip, 3840×2160) | 2.8 %, RSS 68 MB | 0.05 % |

Energy: the Anode CLI's per-app table did not list the probe (an unbundled binary below the top rows), whole-system power republishes in 60 s batches, and WindowServer is root-owned, so **energy per wallpaper was not measured**. The Mac was on battery (84 %) for these runs.

**Step 8 — web.** `WKWebView` with the Global Constraints configuration (non-persistent store, autoplay allowed, muting user script, local file with read access limited to its folder):
- (a) local HTML (80-circle canvas animation + `<video autoplay loop>`): renders and animates; the video was `muted=true` and playing; **20.1 % of a core showing → 0.05 % after the pause recipe (suspend media + `anode-pause` event + removed from window) → 0.15 % with the window ordered out alone.** Both far under 0.5 %.
- (c) plain page (example.com): 0.12 % showing, 0.05 % after both.
- (b) YouTube: **navigating straight to `https://www.youtube.com/embed/<id>?…` fails with "Video player configuration error 153"** (`…-youtube-error153.png`): the embed needs a referring page. **Fix, measured working:** load an HTML wrapper with `loadHTMLString(html, baseURL: https://anode.app/)` containing `<iframe src="https://www.youtube.com/embed/<id>?autoplay=1&mute=1&loop=1&playlist=<id>&controls=0&playsinline=1&rel=0&origin=https://anode.app" allow="autoplay; encrypted-media">` (`…-youtube-iframe.png`; plays, muted, loops through `playlist=<id>`). Cost: 7.0 % showing, **0.65 % after the plan's recipe (over the 0.5 % target, because a cross-origin iframe cannot be paused from the outer page), 0.45 % with the window ordered out.** To pass, either use the IFrame API (`enablejsapi=1`, `postMessage({"event":"command","func":"pauseVideo"})`) or order the window out for web pages. Task 5 must change the YouTube path to the wrapper page.
- The page's captions show by default on this clip; add `cc_load_policy=0`.

**Step 9 — image.** A 12000×8000 PNG downsampled with `CGImageSourceCreateThumbnailAtIndex` to 3600×2400: 0.22 s, live image ≈ 32 MB, peak RSS 78 MB during the decode (12 MB before). One screen's worth, as planned. (My "naive decode" comparison was lazy and means nothing.)

**Step 10 — tiles: NO-GO for Task 9 as designed.** Cut a 20 s 1080p clip into 12 HEVC tiles (4×3, 480×360) with `AVAssetExportSession`: 0.4 s per tile, 43 MB total. Played in 12 windows with 12 `AVQueuePlayer`+`AVPlayerLooper`: **15.5 % of a core, RSS 102 MB, against 1.6–2.0 % for one full-frame 1080p player: about 8× (limit was 1.3×).** With 9 of 12 paused: 5.3 % (about 2.7×). Per-tile cost is ~1.3 % of a core, so a tiled wallpaper only wins when about one or two tiles are visible. Resume of a tile paused 10 s with a zero-tolerance seek to the shared clock: **seek 6 ms, playing again after 98 ms**, 96 ms behind its neighbour at that moment (just inside the 100 ms limit, with a visible-seam risk). Per-tile occlusion itself works (Step 4). GPU and energy not measured; CPU alone already fails. Do not build Task 9 unless the owner wants a different approach (for example 2–3 large regions instead of 12).

**Step 11 — menu bar.** Inconclusive: over the playing video the bar showed white text on black, as it did before; I could not separate system wallpaper from our window (the backdrop is dark either way). Needs a bright clip and the owner's eyes.

**Decision (Step 13).** Core: **GO**, with two open items for the owner: Step 5 (sleep/wake, lock, external display) and the by-eye check that Space switches do not flash the old wallpaper. Tiles: **NO-GO**. Defaults the measurements justify: pause on battery / Low Power / heat / locked / display asleep are cheap to honour (paused video 0.05 %, paused page 0.05–0.65 %); "covered" must use window-list geometry or the full-screen-app signal, not `occlusionState` of the whole window; keep the 0.5 s gate.

## Built (2026-11-06, branch `live-wallpapers`, Tasks 2–7; not merged)

Tasks 2–7 are built and unit-tested (full suite 1951 tests, 0 failures). Not built: Task 8 (its premise, Step 12, was never measured), Task 9 (tiles, spike NO-GO), Task 10 (needs the owner). Where this contradicts the Global Constraints above, **this section wins**:

- **Covered** = the wallpaper window's whole-window `occlusionState` only. `fullScreenApp`, the `fullScreen` condition and the controller's `fullScreen` closure do not exist. A maximized window does not pause it (the menu-bar strip stays visible); the UI says so. Pausing behind maximized windows needs window-list geometry, which needs polling: a separate design.
- **Gate delay is 1.0 s**, not 0.5 s: a Space slide hides the window for ~0.54 s.
- **YouTube** loads through a wrapper page (`loadHTMLString`, base `https://anode.app/`, iframe with `enablejsapi=1`) and is paused/resumed through the IFrame API. It is always muted.
- **A paused web page keeps its last picture** (a snapshot placeholder) before the web view is removed.
- **Links retry on network return**: the controller watches the network (`NWPathMonitor`) only while a link-based wallpaper is failed and waiting.
- **Main-frame navigation** is limited to https/file/about even mid-redirect; a page that is turned away, is a download, or takes over 30 s to load is reported as failed.
- **Sound** for pages is an injected script with a per-surface random switch name; containment of the obvious routes, not a guarantee. Verify hostile-audio behaviour in Task 10 step 5.
- Speed slider is enabled only for videos; the first item added becomes the default.
- Review minors deferred: `.m3u8` should always stream; `refresh` flag dropped when displays change in the same event; Beta rows rebuild on every status change; stray `download-*` file after a crash; image re-decode race; a few test gaps.
- Unverified on hardware: sleep/wake, lock/unlock, external display, Space-switch flash, a hostile page's audio, YouTube pause via the IFrame API, `pmset -g assertions` while a web video plays.
