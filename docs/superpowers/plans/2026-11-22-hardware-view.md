# Hardware View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Beta feature, "Hardware View", that opens one window drawing the Mac's internals with every live reading placed on the part it describes.

**Architecture:** Pure model in PowerKit (family resolution, layout data, photo mapping, reading binding, hover detail, in-memory history). Thin AppKit layer in AnodeApp (one custom-drawn canvas view, window, controller, feature checkbox). The controller exists only while the setting is on (the Game Mode shape) and is fed from the existing main-thread half of the sampling tick. No timers of its own.

**Tech Stack:** Swift, AppKit `draw(_:)`, existing `Palette`, `Motion`, `SparkGraphView`, `FanControlPanel`, `HistoryStore`. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-11-22-hardware-view-design.md`. Visual blueprint (positions, colours, copy, layout numbers): `docs/superpowers/hardware-view-assets/mockup-source.html` (read its `LAYOUTS` object and `DRAW.*` functions; `README.md` in the same folder explains the photo mapping). Photo: `docs/superpowers/hardware-view-assets/macbook-pro-teardown-straightened.jpg`.

## Global Constraints

- Work only in `/Users/noahhoward/Downloads/Programs/Projects/Anode-hardware-view` (branch `hardware-view`, cut from `origin/main`, v1.27.2). Never touch the main checkout.
- **Subagents only edit.** They never run `swift build`, `swift test`, `./test.sh`, `git commit` or `git push`. Tests are written in each task and run once, together, by the lead at the end (CLAUDE.md). Use model `sonnet`.
- Do not change `VERSION`, `CHANGELOG.md` or `UPDATE-NOTE.md` (done by the lead only when the owner says push).
- Never put a tester's name, or words like "friend", in a comment, test or commit.
- No timer, thread or observer exists while `Settings.hardwareViewEnabled` is off. The tick hook is nil-guarded.
- Redraw only when the window is drawable: `window.occlusionState.contains(.visible) && !window.isMiniaturized && ScreenWatch.shared.isWatched`. Data is always stored; drawing is skipped otherwise.
- Nothing animates on its own (`Motion.swift` rule). Fan blades turn only while the window is drawable, at most 20 frames a second, speed scaled from rpm (0.35 to 1.6 turns a second), stopped at 0 rpm, and not at all with Reduce Motion.
- Honesty: every value carries `Provenance` (`.real`, `.estimate`, `.example`). Never show per-core, per-die or per-cell figures, Wi-Fi signal strength or display temperature. A missing reading shows "—", never 0.
- A real reading always overrides the drawing: if the SMC's fan count differs from the layout's, use the generic layout.
- Follow the Memory Watch / Game Mode patterns; tests follow `ThrowawaySettings` / `TestDefaults` and never touch `Settings.shared`, `UserDefaults.standard` or `defaultFeatures(hasLidSensor:)` without `settings:` (`NoSharedSettingsInTestsTests` fails the suite otherwise).
- Colours and fonts come from `Palette`. Corner radii from `Palette.Radius`.

## Review Focus

1. **Unknown or new Mac model** → generic schematic, never a wrong picture. Test `MacFamilyResolver` with identifiers and chips it has never seen.
2. **Fan count from the SMC disagrees with the layout** (or `sensorsSampled == false`) → generic layout / "—", never "fanless" or "0 rpm" by mistake.
3. **Fanless Mac (Neo) and desktops (no battery, no display)** → no fan sliders, no battery or display readouts, no crash on nil readings.
4. **Fan helper not installed** → sliders become a quiet install prompt; nothing installs implicitly.
5. **Window narrow, hidden, miniaturized, or setting turned off while open** → component-jump chips in narrow; no drawing when hidden; window and controller torn down when off.

---

## File Structure

PowerKit (pure, testable):
- `Sources/PowerKit/MacFamily.swift`: `MacFamily`, `MacFamilyResolver`.
- `Sources/PowerKit/PhotoWarp.swift`: the two-step straightening map.
- `Sources/PowerKit/HardwareLayout.swift`: layout value types.
- `Sources/PowerKit/HardwareLayouts.swift`: the five layouts as data.
- `Sources/PowerKit/HardwareReadings.swift`: `Provenance`, `Tagged`, `HardwareReadings`, builder.
- `Sources/PowerKit/HardwareDetail.swift`: hover / pinned detail model.
- `Sources/PowerKit/HardwareHistory.swift`: in-memory ring buffers (empty at open).
- `Sources/PowerKit/Settings.swift`: `hardwareViewEnabled` (six edits).

AnodeApp:
- `HardwareViewFeature.swift`, `HardwareViewController.swift`, `HardwareViewWindow.swift`.
- `HardwareCanvasView.swift` (the view, scale, hit testing), `HardwareCanvasDrawing.swift` (drawers per component kind), `HardwareDesktopDrawing.swift` (display with macOS desktop), `SVGPath.swift` (path string to `NSBezierPath`), `HardwareFanBlades.swift`.
- Edits: `BetaFeaturesWindow.swift`, `main.swift`, `AppMenu.swift`, `FanControlPanel.swift`, `build-app.sh`; new `Resources/HardwareView/macbook-pro-teardown.jpg`.

Tests (`Tests/PowerKitTests/`): `HardwareViewSettingsTests`, `MacFamilyTests`, `PhotoWarpTests`, `HardwareLayoutTests`, `HardwareReadingsTests`, `HardwareDetailTests`, `HardwareViewFeatureTests`, `HardwareViewControllerTests`, `HardwareViewWiringTests`.

---

### Task 1: Setting and Beta Features checkbox

**Files:**
- Modify: `Sources/PowerKit/Settings.swift` (key, default, `Values` field, accessor, change diff, snapshot reader; copy the six `memoryWatchEnabled` edit sites at about lines 113, 275, 399, 1202, 1487, 1703)
- Create: `Sources/AnodeApp/HardwareViewFeature.swift`
- Modify: `Sources/AnodeApp/BetaFeaturesWindow.swift` (append `HardwareViewFeature(settings: settings)` on its own statement right after the `MemoryWatchFeature` line, about :68)
- Test: `Tests/PowerKitTests/HardwareViewSettingsTests.swift`, `Tests/PowerKitTests/HardwareViewFeatureTests.swift`

**Interfaces:**
- Produces: `Settings.Key.hardwareViewEnabled: String`, `Settings.hardwareViewEnabled: Bool` (default `false`), `final class HardwareViewFeature: BetaFeature` with `init(settings: Settings)`; title "Hardware View"; summary one plain sentence (the Mac's internals, each reading on its part).

- [ ] **Step 1: Write the tests** mirroring `MemoryWatchSettingsTests` and `MemoryWatchFeatureTests`: `testDefaultsOff`, `testRoundTripsThroughASecondSettings`, `testObserverFiresOnlyOnChange`, `testCheckboxWritesTheSetting`, `testRegisteredInDefaultFeatures` (`try throwawayBetaWindow(owner: "HardwareView").features.contains { $0 is HardwareViewFeature }`).
- [ ] **Step 2: Implement** the six Settings edits, then `HardwareViewFeature` (checkbox property, `makeView()` sets target/action, `toggled()` writes the setting then `refresh()`, `refresh()` syncs state and calls `layoutChanged?()`, observe token kept in `[AnyObject]`), then register it.

### Task 2: Mac family resolution

**Files:**
- Create: `Sources/PowerKit/MacFamily.swift`
- Test: `Tests/PowerKitTests/MacFamilyTests.swift`

**Interfaces:**
- Produces:
  - `public enum MacFamily: String, Equatable { case macBookPro14ProMax, macBookPro16ProMax, macBookPro14Base, macBookNeo, macMiniM4, generic }`
  - `public struct MacTraits: Equatable { public var model: String; public var chip: String; public var fans: FanPresence.State; public var hasBattery: Bool; public var builtInDisplayPixelWidth: Int? }` with a memberwise `public init`.
  - `public enum MacFamilyResolver { public static func resolve(_ t: MacTraits) -> MacFamily }`
- Rules (no model-identifier table; use traits, which survive new models): chip containing "A18" → `.macBookNeo`, but only when `fans == .fanless`. Laptop (`hasBattery` and a display width): width 3024 is 14-inch, 3456 is 16-inch; chip containing "Pro", "Max" or "Ultra" with `.fans(2)` → the ProMax family for that size; a base chip (none of those words) at 3024 with `.fans(1)` → `.macBookPro14Base`. No battery and no display and `.fans(1)` and chip containing "M4" → `.macMiniM4`. Anything else, including `.unknown` fans, → `.generic`.

- [ ] **Step 1: Write tests**: this Mac (`model "Mac17,9"`, chip "Apple M5 Pro", `.fans(2)`, battery, width 3024) → `.macBookPro14ProMax`; same with `.fans(1)` → `.generic` (Review Focus 2); `.unknown` fans → `.generic`; A18 Pro fanless laptop → `.macBookNeo`; A18 Pro with fans → `.generic`; base M4 with one fan at 3024 → `.macBookPro14Base`; 3456 + Max + 2 fans → `.macBookPro16ProMax`; no battery, no display, one fan, "Apple M4" → `.macMiniM4`; `model "Mac99,1"`, chip "Apple M9" → `.generic` (Review Focus 1).
- [ ] **Step 2: Implement** `MacFamilyResolver.resolve` per the rules.

### Task 3: Photo mapping and layout data

**Files:**
- Create: `Sources/PowerKit/PhotoWarp.swift`, `Sources/PowerKit/HardwareLayout.swift`, `Sources/PowerKit/HardwareLayouts.swift`
- Test: `Tests/PowerKitTests/PhotoWarpTests.swift`, `Tests/PowerKitTests/HardwareLayoutTests.swift`

**Interfaces:**
- Produces:
  - `public struct HWPoint: Equatable { public var x: Double; public var y: Double }`, `public struct HWRect: Equatable { x, y, w, h: Double }`.
  - `public struct PhotoWarp { public static let straightened: PhotoWarp; public func map(photoX: Double, photoY: Double) -> HWPoint }` where inputs are the original photo's "display" pixels (2296 wide) and the output is in straightened-photo pixels (1700 x 1165). Constants from `docs/superpowers/hardware-view-assets/warp.json` (`H`, `K`, `RA`, `RB`, `RR`); formula as `WP()` in `mockup-source.html`.
  - `public enum Confidence { case verified, inferred }`.
  - `public enum HardwareComponentKind: Equatable { case display, fan(index: Int), heatPipe, memory, storage, wifi, antenna, powerIn, battery, speaker, trackpad, board, soc, psu, note }`.
  - `public struct HardwareComponent { public let id: String; public let kind: HardwareComponentKind; public let rect: HWRect?; public let points: [HWPoint]; public let confidence: Confidence; public let jump: HWRect?; public let jumpLabel: String? }` (`points` is used for pipe paths and fan centres; `jump` is the narrow-window focus rectangle).
  - `public struct HardwareLayout { public let family: MacFamily; public let title: String; public let size: HWRect; public let photoResource: String?; public let components: [HardwareComponent] }` with `public static func layout(for family: MacFamily) -> HardwareLayout`.
- Consumes: `MacFamily` (Task 2).
- Data: transcribe `LAYOUTS` from `mockup-source.html` (drawing units 1100 x 1205 for the MacBook Pro photo layout, 1100 x 1130 for the drawn laptops, `vb` for the mini). For the photo layout apply `PhotoWarp.straightened.map` to the photo-pixel positions exactly as the mockup's `P()` does (`x = 40 + u * 1020/1700`, `y = 468 + v * 1020/1700`), including the symmetric pipe `wpath` (already in straightened pixels, in `pipe-symmetric.json`), memory modules and NAND chips at the chassis fractions in `DRAW.pmem` / `DRAW.pssd`, the cells, and `jump` rectangles. Fan counts: ProMax 2, Base 1, Neo 0, Mini 1, generic 2.

- [ ] **Step 1: Write tests**: `PhotoWarpTests.testKnownPointsMatchTheMockup` (assert `map(434, 488)` and `map(1845, 481)` equal the mockup's `WP` outputs to within 0.5 px; compute the expected values by running the formula in the test, not by hardcoding unverified numbers) and `testRightWallIsVerticalAfterCorrection` (points on the fitted wall map to equal x within 1 px). `HardwareLayoutTests`: every family returns a layout; fan components equal that family's fan count; the Neo layout has no `.fan`; the mini layout has no `.battery` or `.display`; every component id is unique; `heatPipe` points are left-right symmetric about the centre line within 2 units (Review Focus 3).
- [ ] **Step 2: Implement** `PhotoWarp` and the value types, then the five layouts in `HardwareLayouts.swift`.

### Task 4: Reading binding, detail model and history

**Files:**
- Create: `Sources/PowerKit/HardwareReadings.swift`, `Sources/PowerKit/HardwareDetail.swift`, `Sources/PowerKit/HardwareHistory.swift`
- Test: `Tests/PowerKitTests/HardwareReadingsTests.swift`, `Tests/PowerKitTests/HardwareDetailTests.swift`

**Interfaces:**
- Produces:
  - `public enum Provenance { case real, estimate, example }`; `public struct Tagged<T> { public var value: T?; public var provenance: Provenance }` (nil value means "—").
  - `public struct HardwareReadings` with: `fans: [FanReading]` (`index`, `rpm`, `minRPM`, `maxRPM`, `targetRPM`, `isManual`), `fansMeasured: Bool` (false when `sensorsSampled == false`), `cpuTemp`, `gpuTemp`, `cpuSensorCount`, `gpuSensorCount` (`Tagged<Double>`/Int), `memory: MemoryReading?` (`app`, `wired`, `compressed`, `free`, `total` in bytes, `pressure: Int32`, `swapBytes: Tagged<UInt64>`), `network: (down: Double, up: Double)?`, `storage: StorageReading?` (`freeBytes`, `totalBytes`, `readBPS`, `writeBPS`, `smartTempC`, `wearPercent`, `spare`, `bytesWritten`), `battery: BatteryReading?` (`percent`, `tempC`, `amps`, `isCharging`, `state`, `timeRemainingMin: Tagged<Int>`, `health`, `cycles`, `designCycles`, `systemDrawW: Tagged<Double>`), `adapter: AdapterReading?` (`ratedW`, `drawnW: Tagged<Double>`, `isCharging`), `display: DisplayReading?` (`brightness`, `watts: Tagged<Double>`).
  - `public static func HardwareReadings.make(system: SystemMetrics.Snapshot, power: PowerMonitor.Snapshot?, swapBytes: UInt64?, brightness: Double?, nvme: NVMeHealth.Sample?, helperInstalled: Bool, manualTargets: [Int: Double]) -> HardwareReadings` (pure).
  - `public struct HardwareDetail { title, confidenceNote, rows: [(label: String, value: String, provenance: Provenance?)], note: String?, series: HardwareSeriesRef? }` and `public static func HardwareDetail.make(component: HardwareComponent, readings: HardwareReadings, history: HardwareHistory, role: String?) -> HardwareDetail?` (`role` picks a battery cell's reading: charge, temp, state, graph, draw, health). Copy wording from the mockup's `detail()` and `CONF`.
  - `public final class HardwareHistory { public init(capacity: Int = 120); public func append(_ r: HardwareReadings); public func series(_ c: Channel) -> [Double?] }` with `Channel` = `cpuTemp, gpuTemp, fanRPM(index:), netDown, netUp, storageRead, memoryUsed, displayWatts`; starts empty and has no disk persistence.
- Consumes: `SystemMetrics.Snapshot` (`fans`, `cpuTemperature`, `gpuTemperature`, `memory`, `network`, `disk`, `sensorsSampled`), `PowerMonitor.Snapshot` (`state`, `scale`, `measured_W`, `display_W`, `displayIsMeasured`), `FanInfo`, `NVMeHealth.Sample`.
- Rules: adapter `drawnW` is `.estimate`; battery `timeRemainingMin` is `.estimate`; `display.watts` is `.real` only when `displayIsMeasured`; temperatures `.real` (mean of sensors); with `sensorsSampled == false` fans are `fansMeasured = false` and temperatures nil (Review Focus 2).

- [ ] **Step 1: Write tests**: provenance per field as above; `fansMeasured == false` and nil temps when `sensorsSampled == false`; a Neo-style input with no fans, no display brightness gives nil `display` and empty `fans` without crashing; `HardwareHistory` starts empty and drops the oldest past capacity; `HardwareDetail.make` for a fan at 0 rpm says "parked", marks the reading `.real`, and a battery `role: "charge"` detail says it is a pack reading; unknown component kind returns nil.
- [ ] **Step 2: Implement** the three files.

### Task 5: Canvas skeleton, SVG path helper, photo and plates

**Files:**
- Create: `Sources/AnodeApp/SVGPath.swift`, `Sources/AnodeApp/HardwareCanvasView.swift`, `Sources/AnodeApp/HardwareCanvasDrawing.swift`
- Modify: `build-app.sh` (copy `Resources/HardwareView/macbook-pro-teardown.jpg` into `Contents/Resources` near the README copy, about :124); create `Resources/HardwareView/macbook-pro-teardown.jpg` by copying the straightened photo
- Test: `Tests/PowerKitTests/SVGPathTests.swift`

**Interfaces:**
- Produces:
  - `enum SVGPath { static func bezier(_ d: String) -> NSBezierPath? }` supporting `M L C Z` with absolute coordinates (used for the Apple logo path and pipe polylines).
  - `final class HardwareCanvasView: NSView { var layout: HardwareLayout; var readings: HardwareReadings?; var history: HardwareHistory?; var isNarrow: Bool; var pinnedID: String?; var onHover: ((HardwareComponent?, NSPoint) -> Void)?; var onClick: ((HardwareComponent?, String?, NSPoint) -> Void)?; override var isFlipped: Bool { true }; func readingsChanged() }` scales layout units to bounds, draws the lid or desktop and the photo (loaded once from `Bundle.main`, falling back to walking up to the checkout like `AppMenu.swift:461`, and to no picture if absent), hit-tests components, and exposes `static func plate(in:rect:radius:alpha:)` and `static func pill(...)` helpers matching the mockup's glass plates.
- Consumes: `HardwareLayout`, `HardwareReadings`, `Palette`.

- [ ] **Step 1: Write `SVGPathTests`**: a triangle path has the right bounding box; the Apple logo path from `mockup-source.html` (`APPLE_LOGO`) parses (non-nil, bounds about 24 wide); an empty or garbage string returns nil.
- [ ] **Step 2: Implement** `SVGPath`, then the canvas view with the photo layer, scale and hit testing, then the shared plate and pill drawing helpers. Draw nothing for a component whose reading is nil except "—".

### Task 6: Component drawers

**Files:**
- Modify: `Sources/AnodeApp/HardwareCanvasDrawing.swift`
- Create: `Sources/AnodeApp/HardwareDesktopDrawing.swift`

**Interfaces:**
- Produces: `extension HardwareCanvasView` drawers, one per kind, each taking `(component, readings)`: heat pipe (heat colour stops 30 to 95 °C, split halves CPU/GPU, symmetric path, pills "CPU 41°" / "GPU 41°"), fans (hub plate with rpm or "PARKED", slider block under each fan with AUTO/MANUAL chip or install prompt), memory (two module plates with composition bar and pressure colour: green, yellow, red), storage (two NAND outlines, readout between), wifi plate, power-in plate ("≈" for estimates), the six battery cells (charge, temp, state, 24 h graph, system draw, health), and the display as a macOS desktop (`HardwareDesktopDrawing`): wallpaper from three radial gradients, menu bar with the Apple logo, "Anode" and menus on the left of the notch, Anode's real menu bar widgets (read from `MenuBarWidgets` config; label above value, as `WidgetRenderer.textImage` draws them) on the right, and the display readout widget (power, brightness, graph).
- Consumes: Task 5 helpers, `Palette`, `SparkGraphView`/`HistoryGraphView` for graphs. All wording, colours, sizes and offsets come from the mockup's `DRAW.*`. Heat colours: `[(30,(58,118,240)),(50,(79,172,236)),(65,(242,178,74)),(80,(255,122,61)),(95,(255,77,58))]`.

- [ ] **Step 1: Implement** the drawers; fans with `fansMeasured == false` draw "—" in the hub, not "PARKED". Fanless and desktop layouts simply have no such components, so nothing draws for them.
- [ ] **Step 2: Add a source-scan test** in `HardwareViewWiringTests` (Task 9) that `HardwareCanvasDrawing.swift` contains no `Timer(` and no `Motion.shared.start(` outside `HardwareFanBlades.swift`.

### Task 7: Hover, pinned detail and narrow jump chips

**Files:**
- Modify: `Sources/AnodeApp/HardwareCanvasView.swift`
- Create: `Sources/AnodeApp/HardwareViewWindow.swift` (the card views live here)

**Interfaces:**
- Produces: a hover tooltip and a pinned card (an `NSView` with a close button) built from `HardwareDetail`; a row of component chips shown when the window is narrower than 640 pt (selecting one eases the canvas to that component's `jump` rectangle using `Eased`, no timer of its own); a tag drawn as REAL, EST or EXAMPLE per row.
- Consumes: `HardwareDetail.make`, `HardwareComponent.jump`.

- [ ] **Step 1: Implement** hover (tracking area, `mouseMoved`), click-to-pin, Escape or the close button unpins, keyboard focus order follows layout order. Tooltip text comes only from `HardwareDetail`.

### Task 8: Fan blades and visibility gating

**Files:**
- Create: `Sources/AnodeApp/HardwareFanBlades.swift`
- Modify: `Sources/AnodeApp/HardwareCanvasView.swift`

**Interfaces:**
- Produces: `struct FanBladeSpin { static func turnsPerSecond(rpm: Double, minRPM: Double, maxRPM: Double) -> Double }` returning 0 at 0 rpm and `0.35 + 1.25 * clamp((rpm-min)/(max-min), 0, 1)` otherwise; `HardwareCanvasView.setAnimating(_ on: Bool)` starts or stops redraw of the fan areas only through `Motion.shared.start(view)` at a frame step of at least 50 ms, and does nothing under `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`. The 33-blade flat impeller is drawn as in the mockup's `DRAW.pfan` (`r0 = 80 * s`, `r = 126 * s`, control point offset `-0.07 r`), over a dark disc, with one fixed highlight that does not rotate; at 0 rpm the photo shows unchanged.

- [ ] **Step 1: Write `FanBladeSpinTests`** in `HardwareReadingsTests.swift`: 0 rpm gives 0; min rpm gives 0.35; max rpm gives 1.6; a value above max is clamped to 1.6.
- [ ] **Step 2: Implement** the spin function and the capped, visibility-gated animation.

### Task 9: Controller, window, tick hook and menu

**Files:**
- Create: `Sources/AnodeApp/HardwareViewController.swift`
- Modify: `Sources/AnodeApp/HardwareViewWindow.swift` (the `NSWindowController`)
- Modify: `Sources/AnodeApp/main.swift` (property near :76, creation near :464, tick hook in the main-thread block next to `self.gameMode?.refresh()` at about :1225, `samplingNeeds`/`tickIsHidden` at about :902 and :897, `fansAreDriven` at about :979, shutdown at about :2929)
- Modify: `Sources/AnodeApp/AppMenu.swift` (hidden-until-on item following `ultraLowPowerItem()`, shown in `menuNeedsUpdate` at about :333)
- Modify: `Sources/AnodeApp/FanControlPanel.swift` (a small forwarding method so the canvas can send the same `FanSession` gestures the Fans strip sends: `setSpeed`, `release`; never installs the helper implicitly)
- Test: `Tests/PowerKitTests/HardwareViewControllerTests.swift`, `Tests/PowerKitTests/HardwareViewWiringTests.swift`; update `GameModeSamplingTests.swift` for the new `samplingNeeds` parameter (give it a default so the old two-argument call still compiles)

**Interfaces:**
- Produces:
  - `final class HardwareViewController { static weak var current: HardwareViewController?; init(settings: Settings, makeWindow: @escaping () -> HardwareViewWindowing, readFamilyTraits: @escaping () -> MacTraits, swapBytes: @escaping () -> UInt64?, brightness: @escaping () -> Double?, helperInstalled: @escaping () -> Bool, sendFan: @escaping (FanGesture) -> Void, batteryHistory: @escaping () -> [Double?], onChange: @escaping () -> Void); func feed(system: SystemMetrics.Snapshot, power: PowerMonitor.Snapshot?); var isShowing: Bool; var wantsFastCadence: Bool; func show(); func shutdown() }` (`FanGesture` is the existing `FanSession` gesture type; use its real name).
  - `protocol HardwareViewWindowing: AnyObject { var onClose: (() -> Void)? { get set }; func show(); func close(); func update(layout: HardwareLayout, readings: HardwareReadings, history: HardwareHistory) }`.
  - `SystemMetrics.Needs` for this window: `[.cpu, .memory, .gpu, .network, .disk, .sensors]` via `samplingNeeds(base:gameShowing:hardwareViewShowing: Bool = false)`.
- Behaviour: observes `Settings.Key.hardwareViewEnabled`; creates nothing while off; on `feed`, builds `HardwareReadings.make`, appends to `HardwareHistory`, and calls `window.update` (the window redraws only if drawable). `swapBytes` is read at most once per tick and only while showing. `batteryHistory` is read at most once a minute and off the main thread, from `HistoryStore.powerSeries(since:until:maxPoints:)`. Turning the setting off closes the window and clears state; closing the window does not turn the setting off. The family is resolved once at enable and re-resolved if the fan count changes (Review Focus 2). Sliders show the install prompt unless `helperInstalled()`.

- [ ] **Step 1: Write the tests**: `testNothingExistsWhileOff` (controller built with the setting off makes no window), `testEnablingMakesWindowOnShow`, `testDisablingClosesWindowAndClearsHistory`, `testFeedWhileHiddenStoresButWindowIsToldOnlyOnUpdate`, `testSwapReadOnlyWhileShowing`, `testFanCountMismatchUsesGenericLayout`, and in `HardwareViewWiringTests` source-scan assertions on `main.swift`: exactly one `hardwareView?.feed(` call site, inside the main-thread block after `self.gameMode?.refresh()` is not required but it must not sit inside `sampleGate.submit(on: sampling)`; no `Timer(` in the new files; the menu item is hidden by default.
- [ ] **Step 2: Implement** controller, window controller (`NSWindow` titled, closable, miniaturizable, resizable, minimum size 420 x 520; `isDrawable` property overridable by tests; `finishClosing()` idempotent), main.swift wiring, the menu item, the `FanControlPanel` forwarder, and the `samplingNeeds` parameter. OR the controller's `wantsFastCadence` into `fansAreDriven` only while a slider gesture is held.

### Task 10: Drawn layouts for the other families

**Files:**
- Modify: `Sources/AnodeApp/HardwareCanvasDrawing.swift`

**Interfaces:**
- Consumes: layouts from Task 3 for `.macBookPro14Base`, `.macBookNeo`, `.macMiniM4`, `.generic`, `.macBookPro16ProMax`.
- Produces: the drawn (not photographed) chassis for those families, matching the mockup: base, board, SoC package with die, fan housings and blades (drawn flat), passive spreader for the Neo, PSU and bottom-plate antenna for the mini, and the plainly labelled "Generic schematic" frame for `.generic`. Components whose reading is nil are omitted. The 16-inch layout reuses the 14-inch ProMax data and photo and says so in its note.

- [ ] **Step 1: Implement** the drawn chassis and kinds not used by the photo layout (`board`, `soc`, `psu`, `speaker`, `trackpad`, `note`).

### Task 11: Whole-branch review and one build

**Files:** none (lead only).

- [ ] **Step 1:** A fresh reviewer (Sonnet) reads the branch diff against the spec and this plan and reports findings by severity; fix findings with one implementer.
- [ ] **Step 2:** The lead runs one `swift build` in the worktree (not tests) and fixes compile errors with edit-only subagents.
- [ ] **Step 3:** The lead runs `./update.sh` from the worktree only if the owner asks to try it, then verifies by window-only capture that the window matches the mockup, in both wide and narrow sizes, parked and under load.
- [ ] **Step 4:** Stop. Report to the owner. Version bump, CHANGELOG, UPDATE-NOTE, `./test.sh --full`, tag, push and release happen only after the owner says push.

---

## Self-review

- **Spec coverage:** Beta feature and off by default (T1, T9); layout as data and family resolution (T2, T3); honest readings and provenance (T4); picture and straightening (T3, T5); every component drawn (T6, T10); hover, pin, narrow (T7); blades and efficiency rules (T8, Global Constraints); fan helper handling (T9); nothing exists while off (T9). Non-goals are enforced by T4's reading types having no per-core, per-die, Wi-Fi-strength or display-temperature fields.
- **Types:** `MacFamily`, `MacTraits`, `HardwareLayout`, `HardwareComponent`, `HardwareReadings`, `HardwareDetail`, `HardwareHistory` and `Provenance` are named identically wherever used.
- **Left to implementers:** exact point sizes and offsets follow the mockup; implementers read it.
