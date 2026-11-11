# Menu Bar Hider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A chevron in the menu bar collapses it to battery, sound, Wi-Fi (plus clock and Control Center); pressing the chevron opens a pill under the notch holding every other icon, arranged by drag and drop in Beta Features.

**Architecture:** Pure logic (item identity, arrangement, cover rectangles, pill geometry, policy, state) lives in `PowerKit` and is unit-tested. AppKit glue (an Accessibility reader, cover panels, the pill panel, the chevron status item, the Beta Features section) lives in `AnodeApp` behind small protocols so `MenuBarHiderController` is tested with fakes. Nothing real (window, status item, Accessibility call) is created by a test; the real thing runs only in the hardware tasks.

**Tech Stack:** Swift 5.9, SwiftPM, AppKit, ApplicationServices (AX), ScreenCaptureKit (macOS 14+, with an app-icon fallback on 13), XCTest. No new dependencies. Deployment target macOS 13.

**Spec:** `docs/superpowers/specs/2026-11-10-menu-bar-hider-design.md` (supersedes `docs/superpowers/plans/2026-11-05-menu-bar-hider.md`). Probe code to reuse: `docs/superpowers/spikes/2026-11-10-menu-bar-hider-ax-probe.swift`.

## Global Constraints

- Setting `menuBarHiderEnabled`, default `false`; Beta Features section titled "Menu Bar Hider". With it off nothing exists: no cover, no observers, no timers, no chevron.
- Every call into another app's accessibility tree uses `AXUIElementSetMessagingTimeout(el, 0.4)` or less and runs off the main thread (memory `anode-freeze-root-cause`).
- Pressing the chevron (never hover) opens the pill. Shortcut default ⌃⌥⌘B. "Hide again after" choices 5 s / 10 s / 30 s / Never, default 10 s.
- Anode's own widgets that are behind the chevron are **destroyed, not hidden** (`isVisible = false` persists per `autosaveName`).
- Never cover anything during full-screen apps or within 1 s of a Space or display change; a cover is removed whenever the layout it was computed for is unreadable or has changed.
- Clock, Control Center and the chevron itself can never be hidden.
- v1 acts only on the screen that carries the status items; elsewhere it stands down (chevron stays, no cover).
- Settings live in UserDefaults suite `com.anode.settings`, keys prefixed `anode.`. Tests use `TestDefaults.make(owner:test:)` and the literal `"anode." + key`.
- Work on a branch `menu-bar-hider` cut from `main`; stage files by name (never `.vscode/launch.json`); commit messages never contain tester names; commits end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. Do not push or merge without asking.
- The owner uses the Mac while this is built. No clicks, drags, app activation or cursor movement on the real machine without asking (hardware tasks 9 and 15 are the only ones that need it).
- After the last code task, run `./build-app.sh` and verify `BSSourceCommit` and the running inode (memory `rebuild-anode-after-every-change`).

## Review Focus

Failure modes the spec implies that no single task's happy path exercises; each has a test in the named task.

1. An item parked at x −1…7, y 1157 (off the bar), zero or negative size, or off every screen must never produce a cover and never count as "on the bar" (Task 4).
2. Two items from one app (OpenVPN ×2) get distinct keys; a key survives a change of position; an unnamed item still gets a key (Task 2).
3. A failed or timed-out read removes the cover instead of keeping the old one; a layout that changed between read and apply is not covered (Task 8).
4. A toggle during full-screen, or within 1 s of a Space change, shows nothing; the pill closes when the screen parameters change (Tasks 6, 8).
5. Switching the feature off, or relaunching with it off, leaves every Anode widget created exactly as before; an arrangement naming an app that is no longer running is ignored, never a crash; the chevron cannot be dragged behind itself (Tasks 3, 7).

## File Structure

- Create `Sources/PowerKit/BarItem.swift`: `BarItem`, `BarItemKey`.
- Create `Sources/PowerKit/BarArrangement.swift`: `BarArrangement`, `BarGroup`.
- Create `Sources/PowerKit/BarGeometry.swift`: `CoverPlanner`, `PillLayout`.
- Create `Sources/PowerKit/HiderPolicy.swift`: `HiderPolicy`, `PillState`.
- Modify `Sources/PowerKit/Settings.swift`: three settings.
- Modify `Sources/AnodeApp/MenuBarWidgets.swift`: fold support.
- Modify `Sources/AnodeApp/Shortcuts.swift`: the toggle command.
- Create `Sources/AnodeApp/MenuBarHider.swift`: protocols and `MenuBarHiderController`.
- Create `Sources/AnodeApp/BarReader.swift`, `BarCoverWindows.swift`, `BarPillWindow.swift`, `BarChevron.swift`.
- Modify `Sources/AnodeApp/BetaFeaturesWindow.swift` (new `MenuBarHiderFeature`) and `Sources/AnodeApp/main.swift` (wiring).
- Tests in `Tests/PowerKitTests/`, one file per task named below.
- Create `docs/superpowers/plans/2026-11-11-menu-bar-hider-results.md` (measurements, departures, not-verified list).

---

### Task 1: Settings

**Files:** Modify `Sources/PowerKit/Settings.swift`; Test `Tests/PowerKitTests/MenuBarHiderSettingsTests.swift`.

**Interfaces:**
- Produces: `Settings.menuBarHiderEnabled: Bool` (default false); `Settings.menuBarHiderAutoCloseSeconds: Int` (allowed 0 = never, 5, 10, 30; anything else reads as 10); `Settings.menuBarHiderArrangement: BarArrangement?` (nil = never arranged; stored as JSON the way `panelOrder` stores its list, tolerant decode); matching `Settings.Key` entries and change notification through `observe(_:)`.

- [ ] **Step 1:** `git switch -c menu-bar-hider`. Write tests `testDefaults`, `testEnabledPersistsAcrossHandles`, `testAutoCloseAllowedValuesRoundTrip`, `testUnknownAutoCloseReadsAsTen`, `testArrangementRoundTripsAndGarbageReadsAsNil`, `testChangeNotifiesOnce` (same shape as `GameModeSettingsTests`). `BarArrangement` does not exist yet: give it a placeholder file in this task containing only `public struct BarArrangement: Codable, Equatable { public var pinned: [String]; public var pillOrder: [String] }` (Task 3 completes it).
- [ ] **Step 2:** `swift test --filter MenuBarHiderSettingsTests`. Expected: FAIL (missing members).
- [ ] **Step 3:** Implement the three settings and keys in `Settings.swift` beside the game-mode ones, snapshot and notify plumbing included.
- [ ] **Step 4:** Same command. Expected: PASS.
- [ ] **Step 5:** Commit `Menu bar hider: settings`.

---

### Task 2: Item identity

**Files:** Create `Sources/PowerKit/BarItem.swift`; Test `Tests/PowerKitTests/BarItemTests.swift`.

**Interfaces:**
- Produces:
  - `public struct BarItem: Equatable { key: String; bundleID: String?; appName: String; title: String; frame: CGRect; isLocked: Bool; hasPress: Bool; pid: pid_t? }` (frame in global top-left screen points, as Accessibility reports it). `isLocked` is true for the clock and Control Center.
  - `public enum BarItemKey { static func make(bundleID: String?, appName: String, identifier: String?, title: String?, description: String?, ordinal: Int) -> String }`: the key is `"<bundleID or appName>|<identifier, else title, else description, else #ordinal>"`, where `ordinal` is the item's index among that app's items sorted by x. It does not contain the position.
  - `BarItem.isOnBar(screens: [CGRect]) -> Bool`: true only when width > 0, height > 0 and the frame lies at least 50 % inside one screen's top-left menu-bar band (the top 40 pt).
  - `BarItem.isLockedItem(identifier:title:) -> Bool` matching Control Center's clock and Control Center items by identifier or title (names come from the probe output recorded in Task 9; until then match "clock" and "controlcenter"/"control center", case-insensitive).

- [ ] **Step 1:** Tests: `testKeyIgnoresPosition`, `testTwoItemsOfOneAppGetDistinctKeysByOrdinal` (same title, ordinals 0 and 1), `testUnnamedItemFallsBackToOrdinal`, `testIdentifierWinsOverTitle`, `testParkedItemIsNotOnBar` (frame x −1, y 1157, w 24, h 24 on a 1800×1169 screen), `testZeroAndNegativeSizeNeverOnBar`, `testItemOffEveryScreenIsNotOnBar`, `testClockAndControlCenterAreLocked`.
- [ ] **Step 2:** `swift test --filter BarItemTests`. Expected: FAIL.
- [ ] **Step 3:** Implement as specified above.
- [ ] **Step 4:** Same command. Expected: PASS.
- [ ] **Step 5:** Commit `Menu bar hider: item identity`.

---

### Task 3: Arrangement model

**Files:** Complete `Sources/PowerKit/BarArrangement.swift`; Test `Tests/PowerKitTests/BarArrangementTests.swift`.

**Interfaces:**
- Consumes: `BarItem`.
- Produces:
  - `public enum BarGroup { case onBar, behindChevron }`.
  - `BarArrangement` (completing Task 1's placeholder; tolerant decode: a damaged field degrades that field): `pinned: [String]` (keys always on the bar), `pillOrder: [String]`.
  - `static func defaultArrangement(for items: [BarItem]) -> BarArrangement`: pins items whose identifier or title contains battery, sound or wi-fi/wifi (case-insensitive); everything else is behind the chevron.
  - `func group(of key: String, items: [BarItem]) -> BarGroup` (locked items are always `.onBar`).
  - `func pillItems(from items: [BarItem]) -> [BarItem]`: items not pinned and not locked, in `pillOrder` order, items missing from `pillOrder` appended in the order given; keys naming no known item are ignored.
  - `func moving(_ key: String, to group: BarGroup, at index: Int, items: [BarItem]) -> BarArrangement`: pure drag-and-drop result; locked items cannot move; index clamps; moving within a group reorders `pillOrder` (for `.onBar` the order is informational only, macOS decides bar order).

- [ ] **Step 1:** Tests: `testDefaultPinsBatterySoundWifi`, `testUnknownItemsLandBehindChevron`, `testPillOrderRespectedThenNewcomersAppended`, `testKeysOfAppsNoLongerRunningAreIgnored`, `testLockedItemsCannotBeMoved`, `testMoveToBehindChevronAtIndexAndClamp`, `testMoveToOnBarUnhides`, `testReorderWithinPill`, `testDamagedFieldDecodesAsEmpty`.
- [ ] **Step 2:** `swift test --filter BarArrangementTests`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Same command. Expected: PASS.
- [ ] **Step 5:** Commit `Menu bar hider: arrangement model`.

---

### Task 4: Cover rectangles

**Files:** Create `Sources/PowerKit/BarGeometry.swift`; Test `Tests/PowerKitTests/CoverPlannerTests.swift`.

**Interfaces:**
- Consumes: `BarItem`, `BarArrangement`.
- Produces: `public enum CoverPlanner { static func covers(items: [BarItem], arrangement: BarArrangement, screen: CGRect, pad: CGFloat = 3) -> [CGRect] }`. Result in top-left screen points. Only on-bar, non-locked, non-pinned items are covered. Each maximal run of adjacent such items (adjacent = no pinned or locked on-bar item between them by x) becomes one rect: from the run's first `minX − pad` to its last `maxX + pad`, full menu-bar height (`screen.minY` to the items' common band height), clamped to the screen. Rects never overlap a pinned or locked item's frame (shrink instead of overlap).

- [ ] **Step 1:** Tests, using the owner's measured layout (Anode widgets x 1114–1500, system items 1507–1780): `testRunOfHiddenItemsIsOneRect`, `testPinnedItemBetweenHiddenSplitsIntoTwoRects`, `testPaddingNeverOverlapsAPinnedNeighbour`, `testParkedAndZeroSizeItemsProduceNoCover` (Review Focus 1), `testNothingHiddenMeansNoCovers`, `testRectClampedToScreen`, `testLockedItemsAreNeverCovered`.
- [ ] **Step 2:** `swift test --filter CoverPlannerTests`. Expected: FAIL.
- [ ] **Step 3:** Implement `CoverPlanner.covers`.
- [ ] **Step 4:** Same command. Expected: PASS.
- [ ] **Step 5:** Commit `Menu bar hider: cover rectangles`.

---

### Task 5: Pill layout

**Files:** Extend `Sources/PowerKit/BarGeometry.swift`; Test `Tests/PowerKitTests/PillLayoutTests.swift`.

**Interfaces:**
- Produces: `public enum PillLayout { static func frames(count: Int, cell: CGSize, maxWidth: CGFloat, padding: CGFloat, spacing: CGFloat) -> (cells: [CGRect], size: CGSize) }` (rows wrap left to right, cells in a local top-left space); `static func origin(size: CGSize, screen: CGRect, notch: CGRect?, menuBarHeight: CGFloat, gap: CGFloat = 4) -> CGPoint` (top-left): horizontally centred under the notch, or at the screen's centre when `notch` is nil, directly below the bar, and clamped inside `screen`.

- [ ] **Step 1:** Tests: `testSingleRowForFewItems`, `testWrapsToSecondRowAtMaxWidth`, `testZeroItemsGivesPaddingOnlySize`, `testCentredUnderNotch`, `testNoNotchCentresOnScreen`, `testClampedWhenWiderThanScreen`.
- [ ] **Step 2:** `swift test --filter PillLayoutTests`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Same command. Expected: PASS.
- [ ] **Step 5:** Commit `Menu bar hider: pill layout`.

---

### Task 6: Policy and pill state

**Files:** Create `Sources/PowerKit/HiderPolicy.swift`; Test `Tests/PowerKitTests/HiderPolicyTests.swift`.

**Interfaces:**
- Produces:
  - `public enum HiderDecision: Equatable { case collapsed; case standDown(HiderRefusal) }` and `public enum HiderRefusal: Equatable { case disabled, noAccessibility, layoutUnreadable, fullScreen, settling, itemsNotOnThisScreen }`.
  - `HiderPolicy.decide(enabled: Bool, accessibilityTrusted: Bool, layoutReadable: Bool, fullScreen: Bool, secondsSinceSpaceOrDisplayChange: TimeInterval, itemsOnThisScreen: Bool) -> HiderDecision`: first matching refusal in the order listed above; `settling` while the time is under 1 s.
  - `public struct PillState: Equatable { var isOpen: Bool; var closeAt: Date? }` with `mutating func toggle(now: Date, autoClose: Int)`, `mutating func close()`, `mutating func tick(now: Date)` (closes when `closeAt` has passed; `autoClose` 0 means never), `mutating func screenParametersChanged()` (closes).

- [ ] **Step 1:** Tests: `testRefusalOrder`, `testSettlingUnderOneSecond`, `testCollapsedWhenAllClear`, `testToggleOpensThenCloses`, `testAutoCloseAfterSeconds`, `testNeverStaysOpen`, `testScreenChangeClosesPill` (Review Focus 4).
- [ ] **Step 2:** `swift test --filter HiderPolicyTests`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Same command. Expected: PASS.
- [ ] **Step 5:** Commit `Menu bar hider: policy and pill state`.

---

### Task 7: Fold Anode's own widgets

**Files:** Modify `Sources/AnodeApp/MenuBarWidgets.swift`; Test `Tests/PowerKitTests/WidgetFoldTests.swift` (beside `WidgetPlacementTests`).

**Interfaces:**
- Consumes: existing `MenuBarWidgetController.effectiveConfigs(_:density:)`, `rebuild()`, `items`.
- Produces: `static func effectiveConfigs(_ stored: [WidgetConfig], density: Density, folded: Set<String>) -> [WidgetConfig]` (the existing two-argument form stays and calls this with `[]`; folded metric IDs are removed after the density rule, and a `.single` density item is also dropped when its metric is folded); `public func setFolded(_ metricIDs: Set<String>)` which stores the set, and triggers `rebuild()` so the folded items are removed with `NSStatusBar.system.removeStatusItem` (the existing teardown), never `isVisible = false`; `public private(set) var folded: Set<String>`; `public static func key(forMetricID:) -> String` returning `"dev.anode.app|widget.<metricID>"` (the key Beta Features and the pill use for Anode's widgets).

- [ ] **Step 1:** Tests on the pure function and key: `testFoldedMetricsAreRemoved`, `testFoldedSetEmptyChangesNothing` (Review Focus 5), `testFoldAppliesAfterDensity`, `testGroupWidgetCanBeFolded`, `testKeyFormat`. Do not construct a controller (it creates status items).
- [ ] **Step 2:** `swift test --filter WidgetFoldTests`. Expected: FAIL.
- [ ] **Step 3:** Implement. `rebuild()` passes `folded` into `effectiveConfigs`. Add a one-line source assertion test `testFoldNeverSetsIsVisibleFalse` that reads `MenuBarWidgets.swift` and asserts the file does not contain `isVisible = false` (the existing pattern for such rules).
- [ ] **Step 4:** `swift test --filter WidgetFoldTests` and `swift test --filter WidgetAutosaveTests`. Expected: PASS.
- [ ] **Step 5:** Commit `Menu bar hider: Anode widgets can be folded away`.

---

### Task 8: The controller, against fakes

**Files:** Create `Sources/AnodeApp/MenuBarHider.swift`; Test `Tests/PowerKitTests/MenuBarHiderControllerTests.swift`.

**Interfaces:**
- Consumes: Tasks 1–7.
- Produces (all in `Sources/AnodeApp/MenuBarHider.swift`):
  - `protocol BarReading { func read(completion: @escaping ([BarItem]?) -> Void) }` (calls back on the main queue; `nil` = unreadable/timed out).
  - `protocol CoverPresenting: AnyObject { func show(_ rects: [CGRect], on screen: CGRect); func removeAll(); var rects: [CGRect] { get } }`.
  - `protocol PillPresenting: AnyObject { func show(items: [BarItem], origin: CGPoint?, press: @escaping (BarItem) -> Void); func hide(); var isShowing: Bool { get } }`.
  - `protocol ChevronPresenting: AnyObject { func install(); func remove(); var onToggle: (() -> Void)? { get set } }`.
  - `protocol WidgetFolding: AnyObject { func setFolded(_ ids: Set<String>); var widgetKeys: [(key: String, metricID: String, title: String)] { get } }` (implemented by `MenuBarWidgetController`).
  - `final class MenuBarHiderController` with `init(settings:reader:covers:pill:chevron:widgets:environment:now:log:)` where `environment` is a closure returning `(trusted: Bool, fullScreen: Bool, secondsSinceChange: TimeInterval, screen: CGRect, notch: CGRect?)`; methods `reevaluate()` (the one place that reads settings and acts), `togglePill()`, `layoutMayHaveChanged()` (re-reads), `shutdown()`; read-only `decision: HiderDecision`, `isCollapsed: Bool`, `static var current: MenuBarHiderController?`; `onChange: (() -> Void)?`; log lines to `menubarhider.log` through `FeatureLog`.
- Behaviour: off → everything removed, widgets unfolded, chevron removed. Collapsed → chevron installed, Anode widgets folded per arrangement (items from `widgets.widgetKeys` are merged into the item list as pseudo-items so they are arrangeable), covers planned by `CoverPlanner` from a fresh read. A failed read removes covers (Review Focus 3). A read that returns items whose frames differ from those the covers were planned for triggers one re-read before showing. Pill items come from `arrangement.pillItems`; pressing an Anode pseudo-item asks `widgets` to open its menu, any other item calls `pressItem`. Pressing an item closes the pill unless the item is Anode's.

- [ ] **Step 1:** Fakes for the four protocols plus a settings suite. Tests: `testOffRemovesEverythingAndUnfolds`, `testCollapsedInstallsChevronAndPlansCovers`, `testRefusalsRemoveCovers` (one per `HiderRefusal`), `testFailedReadRemovesCoverNotKeepsIt`, `testLayoutChangedBetweenReadAndShowRereads`, `testTogglePillShowsHiddenItemsInOrder`, `testPillClosesOnScreenChange`, `testArrangementNamingAbsentAppIsIgnored`, `testAnodeWidgetsFoldedExactlyWhenBehindChevron`, `testTurningOffRestoresWidgets`, `testShutdownRemovesEverything`, `testReevaluateIsIdempotent`.
- [ ] **Step 2:** `swift test --filter MenuBarHiderControllerTests`. Expected: FAIL.
- [ ] **Step 3:** Implement the protocols and controller. No AppKit objects are created inside the controller; it only talks to the protocols.
- [ ] **Step 4:** Same command. Expected: PASS.
- [ ] **Step 5:** Commit `Menu bar hider: controller and its seams`.

---

### Task 9: Hardware measurements (gate for Tasks 10–12)

**Needs the owner at the Mac and their say-so for each probe.** Tasks 1–8 depend on none of this; Tasks 10–12 read its results. Record everything in `docs/superpowers/plans/2026-11-11-menu-bar-hider-results.md`. Probe code goes in `docs/superpowers/spikes/` and is labelled throwaway; no product code in this task.

**Interfaces:** Produces the three results below and the identifiers of the 19 items (which fixes the `isLockedItem` and default-pin names used in Tasks 2–3).

- [ ] **Step 1 (read-only, no permission needed beyond today's):** run the existing AX probe with identifier and title columns added; record each item's identifier, title, frame. Adjust the name matching in `BarItem.isLockedItem` and `BarArrangement.defaultArrangement` to what is real, with a failing-then-passing test each.
- [ ] **Step 2 (risk 1, asks the owner):** with the widget controller's `setFolded` applied to all eight Anode widgets (or Anode's `setEnabled(false)`), re-run the probe. Pass: the six parked items have x ≥ 0 and on-bar. Fail: record it; Task 12's pill still lists them by app icon, and Task 14's section says honestly that macOS keeps them parked.
- [ ] **Step 3 (risk 2, asks the owner, no cursor):** `AXPress` one on-bar item and one parked item, take a screenshot after each, dismiss with `AXCancel` on the menu element (never a click). Record where each menu opened. If the parked item's menu opens off-screen or at the wrong place, record it and keep Task 12's forwarding but with the section's honest note.
- [ ] **Step 4 (risk 3, read-only):** capture the bar band (ScreenCaptureKit) at the notched Mac's three wallpapers (the wallpaper changes every 60 s) and record the colour variance across x 1108–1504. Flat black → Task 10 fills black. Not flat → Task 10 samples the strip beside each cover and the section says a non-flat bar may show a patch.
- [ ] **Step 5:** Write the results document; commit `Menu bar hider: hardware measurements`.

---

### Task 10: The Accessibility reader

**Files:** Create `Sources/AnodeApp/BarReader.swift`; Test `Tests/PowerKitTests/BarReaderTests.swift`.

**Interfaces:**
- Consumes: `BarReading`, `BarItemKey.make`, `BarItem`.
- Produces: `final class AXBarReader: BarReading` (a serial background queue; for each running application with a process id, `AXUIElementCreateApplication`, `AXUIElementSetMessagingTimeout(…, 0.4)`, `AXExtrasMenuBar` children; position, size, identifier, title, description; ordinal per app sorted by x; the whole read bounded at 1.5 s total, returning `nil` past that or when `AXIsProcessTrusted()` is false); `static func parse(app: (bundleID: String?, name: String, pid: pid_t), children: [(identifier: String?, title: String?, description: String?, frame: CGRect, hasPress: Bool)]) -> [BarItem]` (pure); `func press(_ item: BarItem)` performing `AXPress` on the matching element, found again by pid and key, on the same background queue. A `BarEvents` helper (same file) calls a closure on NSWorkspace launch/terminate, active Space change, screen parameter change, and a 30 s fallback timer, and stops when released.

- [ ] **Step 1:** Tests on the pure `parse` only: `testOrdinalsAreOrderedByX`, `testItemWithoutPressActionIsKept`, `testEmptyChildrenGivesNoItems`, `testLockedFlagSetForClock`. No test creates an `AXUIElement` or an observer.
- [ ] **Step 2:** `swift test --filter BarReaderTests`. Expected: FAIL.
- [ ] **Step 3:** Implement `parse`, then the AX reader and events around it.
- [ ] **Step 4:** Same command. Expected: PASS.
- [ ] **Step 5:** Commit `Menu bar hider: accessibility reader`.

---

### Task 11: Cover panels

**Files:** Create `Sources/AnodeApp/BarCoverWindows.swift`; Test `Tests/PowerKitTests/BarCoverWindowsTests.swift`.

**Interfaces:**
- Produces: `final class BarCoverWindows: CoverPresenting` (one borderless `NSPanel` per rect, `.nonactivatingPanel`, `.screenSaver` level, `canJoinAllSpaces`/`fullScreenAuxiliary`/`stationary`/`ignoresCycle`, `ignoresMouseEvents = false` so a click on the cover is swallowed, fill colour from Task 9 step 4); `static func appKitFrame(forTopLeft rect: CGRect, screenFrame: CGRect) -> NSRect` (pure conversion); `static func fillColor(flat: Bool, sampled: NSColor?) -> NSColor` (black when flat).

- [ ] **Step 1:** Tests: `testTopLeftToAppKitConversion` (menu-bar rect on a 1800×1169 screen), `testConversionOnASecondaryScreenWithOffsetOrigin`, `testFillIsBlackWhenFlat`, `testFillUsesSampleWhenNotFlat`. No window is created.
- [ ] **Step 2:** `swift test --filter BarCoverWindowsTests`. Expected: FAIL.
- [ ] **Step 3:** Implement the pure helpers, then the panels (reuse one panel per rect, reordering in place; `removeAll()` orders out and closes).
- [ ] **Step 4:** Same command. Expected: PASS.
- [ ] **Step 5:** Commit `Menu bar hider: cover panels`.

---

### Task 12: The pill

**Files:** Create `Sources/AnodeApp/BarPillWindow.swift`; Test `Tests/PowerKitTests/BarPillWindowTests.swift`.

**Interfaces:**
- Consumes: `PillLayout`, `PillPresenting`, `WidgetRenderer`, `MenuBarWidgetController.buildGroupMenu`.
- Produces: `final class BarPillWindow: PillPresenting` (non-activating panel recipe of `GameHUDWindow`; rounded dark pill with a subtle border; one clickable cell per item; clicking a cell calls the `press` closure; closes when the user clicks outside it, via a global mouse-down monitor installed only while open and removed on `hide()`); `final class BarPictures` with `static func crop(_ image: CGImage, itemFrame: CGRect, bandOrigin: CGPoint, scale: CGFloat) -> CGRect` (pure crop rectangle), and `func picture(for item: BarItem, completion: @escaping (NSImage) -> Void)` which captures the bar band excluding Anode's windows with ScreenCaptureKit (macOS 14+, Screen Recording granted) and crops by the item's frame; otherwise the app's icon (`NSRunningApplication.icon`), and for parked items the app icon always. Anode's own pseudo-items are drawn with `WidgetRenderer` from live registry values and open the group menu anchored under the cell.

- [ ] **Step 1:** Tests on pure parts: `testCropRectIsInPixelsFromBandOrigin`, `testCropClampsToImage`, `testParkedItemUsesAppIcon` (the rule function `BarPictures.source(for:onBar:captureAvailable:) -> .capture | .appIcon`), `testNoCaptureAvailableUsesAppIcon`.
- [ ] **Step 2:** `swift test --filter BarPillWindowTests`. Expected: FAIL.
- [ ] **Step 3:** Implement the pure helpers, then the panel and the cells.
- [ ] **Step 4:** Same command. Expected: PASS.
- [ ] **Step 5:** Commit `Menu bar hider: the pill`.

---

### Task 13: Chevron, shortcut, right-click menu

**Files:** Create `Sources/AnodeApp/BarChevron.swift`; Modify `Sources/AnodeApp/Shortcuts.swift`; Test `Tests/PowerKitTests/BarChevronTests.swift` (and add a case to `ShortcutsTests.swift`).

**Interfaces:**
- Produces: `ShortcutCommands.hiderToggle` (id `hider.toggle`, title "Show or hide the menu bar icons", section "Menu Bar Hider", default ⌃⌥⌘B), included in `ShortcutCommands.all`; `final class BarChevron: ChevronPresenting` (one `NSStatusItem` with `autosaveName` `AnodeHiderChevron`, created only in `install()` and removed in `remove()`; left-click calls `onToggle`; right-click shows an `NSMenu` built by `static func buildMenu(isOpen: Bool, autoClose: Int, onToggle:, onAutoClose:, onOpenBeta:) -> NSMenu` with "Show icons"/"Hide icons", "Hide again after" 5 s/10 s/30 s/Never with a checkmark on the current choice, and "Open Beta Features…").

- [ ] **Step 1:** Tests: `testToggleCommandDefaultIsControlOptionCommandB`, `testToggleCommandIsInAll`, `testMenuTitleFollowsState`, `testAutoCloseChoicesAndCheckmark`, `testMenuHasOpenBetaFeaturesItem`. The menu is built but not shown.
- [ ] **Step 2:** `swift test --filter BarChevronTests` and `--filter ShortcutsTests`. Expected: FAIL.
- [ ] **Step 3:** Implement the command and `BarChevron`; the controller registers the command with `KeybindCenter.shared.register(owner: "menubarhider", …)` only while collapsed (unregister otherwise), in Task 15's wiring.
- [ ] **Step 4:** Same commands. Expected: PASS.
- [ ] **Step 5:** Commit `Menu bar hider: chevron and shortcut`.

---

### Task 14: Beta Features section with drag and drop

**Files:** Modify `Sources/AnodeApp/BetaFeaturesWindow.swift`; Test `Tests/PowerKitTests/MenuBarHiderFeatureTests.swift`.

**Interfaces:**
- Consumes: `BarArrangement.moving`, `Settings`, the controller's current item list, `AXBarReader`.
- Produces: `final class MenuBarHiderFeature: BetaFeature` (title "Menu Bar Hider"; the enable checkbox; two `NSTableView` lists "Always on the bar" and "Behind the chevron", each row an icon plus name, rows draggable within and between lists, `registerForDraggedTypes` with a private pasteboard type carrying the item key; a drop calls `BarArrangement.moving` and stores it; the "Hide again after" popup; the shortcut note; a status label naming a missing permission with a button to open its pane (Accessibility, Screen Recording) and the note from Task 9 when the parked items did not return). Add it to `defaultFeatures` (always present; it needs no sensor).
- Pure seam: `static func rows(for arrangement: BarArrangement, items: [BarItem]) -> (onBar: [BarItem], behind: [BarItem])` and `func handleDrop(key: String, to group: BarGroup, at index: Int)`, so tests never run a drag.

- [ ] **Step 1:** Tests: `testRowsSplitByArrangement`, `testLockedItemsShownOnBarAndNotDraggable`, `testDropMovesItemAndStores`, `testDropOfUnknownKeyIsIgnored`, `testChevronIsNotListed` (Review Focus 5), `testEnableCheckboxWritesSetting`, `testAutoClosePopupWritesSetting`, `testStatusNamesMissingAccessibility`, `testFeatureIsInDefaultList`.
- [ ] **Step 2:** `swift test --filter MenuBarHiderFeatureTests`. Expected: FAIL.
- [ ] **Step 3:** Implement the feature and its table data sources.
- [ ] **Step 4:** Same command, then `swift test --filter BetaFeaturesWindowTests`. Expected: PASS.
- [ ] **Step 5:** Commit `Menu bar hider: Beta Features section`.

---

### Task 15: Wiring, install, hardware check, notes

**Files:** Modify `Sources/AnodeApp/main.swift`; Modify `MenuBarWidgetController` conformance to `WidgetFolding`; Test `Tests/PowerKitTests/MenuBarHiderWiringTests.swift`; Create `docs/superpowers/plans/2026-11-11-menu-bar-hider-results.md` (extend Task 9's).

**Interfaces:** Consumes everything above. Produces nothing new.

- [ ] **Step 1:** Test `testHiderIsNotCreatedWhenDisabled` and `testShutdownIsCalledAtTerminate` as source assertions on `main.swift` (the existing pattern), plus a `testSamplingNeedsUnchanged` check that the hider adds no sampler needs.
- [ ] **Step 2:** `swift test --filter MenuBarHiderWiringTests`. Expected: FAIL.
- [ ] **Step 3:** In `main.swift`, beside the Game Mode construction, build the controller with the real parts, register the shortcut while collapsed, re-run `reevaluate()` on settings changes, on `BarEvents`, and on `MenuBarWidgetController.itemsDidRebuild`; call `shutdown()` at terminate.
- [ ] **Step 4:** `swift test` (the whole suite; expect 0 failures, report the count) then `./build-app.sh`; verify `BSSourceCommit` and the running inode.
- [ ] **Step 5 (hardware, with the owner and their say-so):** turn the section on; confirm the bar collapses, the six parked icons are reachable from the pill, the chevron opens and closes the pill by click, shortcut and timer, a drag in Beta Features moves an icon between groups and the pill follows; turn it off and confirm everything is back and Anode's widgets are as before; quit Anode while collapsed and confirm the bar is whole. Record each as measured or not verified.
- [ ] **Step 6:** Write the results document (measurements, departures from the spec, not-verified list); commit `Menu bar hider: wiring and results`. Then run the whole-branch review per executing-plans, and stop before any merge or push.
