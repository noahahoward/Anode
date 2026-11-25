# Hardware View in the sidebar — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox syntax.

**Goal:** Move the Hardware View out of Settings → Beta Features and its own window and into the main window as a new sidebar tab ("lens") called Hardware, always available.

**Architecture:** Hardware becomes `SidebarView.Lens.hardware`, a whole-machine tab like Resources/Fans: the main window's `paneContainer` hosts one `HardwareStageView` (already built: canvas, chips, cards). The existing sampling machinery already follows the selected lens (`Lens.needs` → `visibleNeeds`), so the Hardware-View-only tick plumbing (`wantsTick`, `hardwareViewShowing`, the Ultra tweaks) is deleted rather than adapted. `HardwareViewController` stops owning a window and a setting; it is told when the pane appears and disappears and is fed by `refreshPane()`.

**Tech Stack:** Swift 5.9, AppKit, PowerKit. Branch `hardware-view`, worktree `/Users/noahhoward/Downloads/Programs/Projects/Anode-hardware-view`. Nothing in this plan may compile or run tests (the lead builds once at the end).

**Spec:** `docs/superpowers/specs/2026-11-22-hardware-view-design.md` (everything in it still holds except "A Beta feature … opens one Hardware window" and the window chrome, which this plan replaces).

## Global Constraints

- The owner's request (2026-11-23): "implement this into the actual app and not just the beta features, as like a new menu in the left sidebar". Rulings made to carry it out: (1) the Beta feature, its `Settings` key, its Beta Features entry, its menu item and its standalone window are REMOVED, not kept beside the tab (the branch is unreleased, so no migration); (2) the tab is offered on every Mac (the layout is chosen from traits; unknown Macs get the generic schematic); (3) it is the last tab in the rail, with the next free ⌘ number.
- Efficiency, unchanged and binding: nothing for the Hardware View exists or runs while its tab is not on screen (no timer, thread or observer; no history; no provider call); the pane's canvas and fan-blade animation run only when the pane is visible AND the main window is visible, unoccluded, not miniaturized and `ScreenWatch.shared.isWatched`; a reading that arrives while not drawable is stored, not drawn; the sampling tick asks only for what `Lens.hardware.needs` says.
- Honesty rules from the spec are unchanged (real / estimate / example; missing = "—"; the stand-in photo label stays).
- `Tests/PowerKitTests`: never `Settings.shared`, `UserDefaults.standard`, `UserDefaults(suiteName:)`, or `defaultFeatures(hasLidSensor:)` without `settings:`. No tester names or the word "friend".
- Do not change `VERSION`, `CHANGELOG.md`, `UPDATE-NOTE.md`. Subagents only edit: never build, test, commit, stash or push.

## Review Focus

- Switching away from the Hardware tab and back: the pane stops drawing and animating at once, the history and charge cache are cleared when it leaves (as closing the window did), and coming back starts clean with the family re-resolved from traits.
- Opening the tab with the main window hidden/occluded: nothing is drawn until it is visible; the first visible tick draws.
- A Mac with no fans (Neo), one fan, two fans and an unknown model each get the right drawing from the tab (no regression of the family logic).
- The sidebar rail, the View menu (⌘ numbers) and every `switch` over `Lens` stay in step: no lens is missing from one of them (grep every `switch lens` / `case .fans`).
- Removed code leaves no dangling reference: no `hardwareViewEnabled`, `HardwareViewFeature`, `HardwareViewWindowing`, `wantsTick`, `hardwareViewShowing` anywhere in Sources or Tests.

---

### Task 12: Pane and controller (no main.swift, Sidebar, Settings or menu edits)

**Files:**
- Create: `Sources/AnodeApp/HardwarePane.swift` — `final class HardwarePane: NSView` hosting one `HardwareStageView` pinned to its bounds (constraints like `SystemPane`/`install(_:in:)`), implementing the new protocol `HardwareViewHosting` below. It has NO window controller, close button or delegate.
- Modify: `Sources/AnodeApp/HardwareViewController.swift` — replace `HardwareViewWindowing`/window creation with the pane protocol; remove `Settings`, the `Settings.observe` token, `onChange`, `wantsTick`, `isShowing`'s window meaning, `onVisibilityChange`.
- Modify: `Sources/AnodeApp/HardwareViewRuntime.swift` — `live(...)` returns the new controller; drop `onChange`/settings parameters.
- Delete: `Sources/AnodeApp/HardwareViewWindow.swift`, `Sources/AnodeApp/HardwareViewFeature.swift` (move anything still needed, e.g. `isDrawable` rules, into `HardwarePane`).
- Tests: rewrite `Tests/PowerKitTests/HardwareViewControllerTests.swift`; replace `HardwareViewWindowTests.swift` with `HardwarePaneTests.swift`; delete `HardwareViewFeatureTests.swift`.

**Interfaces:**
- Consumes (unchanged): `HardwareStageView` (`update(layout:readings:history:chargeHistory:menuBarWidgets:)`, `onFanSlider`, `onInstallHelper`, `isDrawableNow`, `unpin()`), `HardwareLayout.layout(for:)`, `MacFamilyResolver`, `HardwareReadings.make`, `HardwareHistory`, `Providers` (8+1 closures incl. `heldFans`), `MenuBarWidgetText`.
- Produces:
  ```swift
  protocol HardwareViewHosting: AnyObject {
      var onFanSlider: ((Int, Double?) -> Void)? { get set }
      var onInstallHelper: (() -> Void)? { get set }
      /// True while the pane is on screen and nobody covers it (the drawable rule, injectable for tests).
      var isDrawingNow: Bool { get }
      func update(layout: HardwareLayout, readings: HardwareReadings?, history: HardwareHistory,
                  chargeHistory: [Double?], menuBarWidgets: [MenuBarWidgetText])
      /// Forget a pinned card and stop anything running; called when the tab is left.
      func reset()
  }
  final class HardwarePane: NSView, HardwareViewHosting { init(frame: NSRect); var isDrawable: () -> Bool /* default: window != nil && window.isVisible && occlusion visible && !miniaturized && !isHiddenOrHasHiddenAncestor && ScreenWatch.shared.isWatched */ ... }
  final class HardwareViewController {
      init(providers: Providers, makeHost: @escaping () -> HardwareViewHosting, sendFan: ..., installHelper: ..., now: ...)   // same sendFan/installHelper/now types as today
      var isShowing: Bool            // between paneAppeared() and paneDisappeared()
      func paneAppeared()            // creates the host once, resolves the family from providers.traits(), loads the layout, wires the host's callbacks, starts the charge fetch (<= once/60 s), draws a first frame with nil readings
      func paneDisappeared()         // reset(): clears history, cached readings, charge cache, bumps the charge generation, host.reset()
      func feed(system: SystemMetrics.Snapshot, power: PowerMonitor.Snapshot?)   // returns immediately if !isShowing
      func shutdown()
      static weak var current: HardwareViewController?
  }
  ```
  Everything the 9a/9b/final reviews established stays: fan-count reconcile (`lastResolvedFanCount`, generic fall-back and return), swap read at most once per feed, charge history at most once per 60 s with a generation guard, `heldFans` for MANUAL, `sendFan` forwarded unchanged, `shutdown` idempotent.

- [ ] **Step 1: Write/rewrite the tests** (named, with the spec's values): controller tests keep their existing names where the behaviour survives (`testFeedWhileShowingUpdatesTheHostWithReadingsAndHistory`, `testSwapIsReadAtMostOncePerFeed`, `testChargeHistoryIsFetchedAtMostOncePerMinute`, `testALateChargeHistoryAfterTheTabIsLeftIsIgnored`, `testFanCountMismatchUsesTheGenericLayout`, `testMatchingFanCountKeepsTheFamily`, `testAHeldFanReadsManualAndIsForgottenOnRelease`, `testSendFanIsForwarded`) and gain: `testNothingHappensBeforeThePaneAppears` (no host made, no provider called, `feed` ignored), `testLeavingTheTabClearsHistoryAndCachedReadings`, `testComingBackStartsCleanAndResolvesTheFamilyAgain`, `testShutdownIsIdempotent`. `HardwarePaneTests`: stage is pinned to the pane's bounds, `isDrawingNow` follows the injected `isDrawable`, `reset()` unpins, a covered pane does not mark the canvas `needsDisplay` on `update`.
- [ ] **Step 2: Implement** the files above; delete the two files; nothing outside the listed files changes.

### Task 13: Sidebar tab, wiring, removals

**Files:**
- Modify: `Sources/AnodeApp/SidebarView.swift` (`Lens.hardware`: title "Hardware", symbol an SF Symbol available on macOS 13 such as `laptopcomputer`, `isPerProcess` false, offered on every Mac, `metric` nil, a one-line `summary`, `needs` = `[.cpu, .memory, .gpu, .network, .disk, .sensors]`; rail order = last), `Sources/AnodeApp/main.swift` (the `hardwarePane`/controller properties, `select(_:)` showing the pane and calling `paneAppeared()`/`paneDisappeared()` on enter/leave, `refreshPane()` feeding the controller, `shutdown`; DELETE `wantsTick`/`hardwareViewShowing` plumbing in `tickIsHidden`, `samplingNeeds`, `restartTimer`, `refresh`, the Ultra `tickRuns` additions and the `fansAreDriven` addition, and the stand-alone feed hook), `Sources/AnodeApp/AppMenu.swift` (remove the "Hardware View" menu item and `hardwareViewEntryID`; the View menu gets the new lens through `lensItems`), `Sources/AnodeApp/BottomContext.swift` and any other exhaustive `switch` over `Lens` (grep), `Sources/AnodeApp/BetaFeaturesWindow.swift` (remove the append), `Sources/PowerKit/Settings.swift` (remove the `hardwareViewEnabled` key, default, snapshot field, accessor, notify and snapshot-read sites: all six).
- Tests: update every test that pins the lens list/count, ⌘ numbers, rail icons or `Needs` (grep `Lens.allCases`, `SidebarIconTests`, `displayOrder`, `lensItems`, ⌘5), delete `HardwareViewSettingsTests.swift`, rewrite `HardwareViewWiringTests.swift` (one `hardwareView?.feed(` call site in `refreshPane`, not in the sampling queue; no `Timer(`/`DispatchSource.makeTimerSource` in the Hardware files incl. `HardwarePane.swift`; the old Beta/menu/`wantsTick` assertions go; assert `Lens.hardware` is the last lens and its `needs`), and `GameModeSamplingTests.swift` if `tickIsHidden`/`samplingNeeds` signatures change.

**Interfaces:** Consumes Task 12's `HardwarePane`, `HardwareViewController(providers:makeHost:sendFan:installHelper:now:)`, `paneAppeared()`, `paneDisappeared()`, `feed(system:power:)`, `shutdown()`, and `HardwareViewRuntime.live(...)` (its parameters lose `onChange`/settings; read the file Task 12 leaves).

- [ ] **Step 1: Write/adjust the tests** as listed.
- [ ] **Step 2: Implement** the edits. `select(_:)` must call `paneDisappeared()` on the controller when the lens changes away from `.hardware` and `paneAppeared()` when it changes to it, including when the main window is closed/hidden while on the tab (the drawable rule handles visibility; hide/show of the window does not clear state).

### Task 14: Whole-branch review and the one build

**Files:** none (lead only). Reviewer reads the diff of Tasks 12–13 against this plan and the Global Constraints; the lead then runs `swift build` and `swift build --build-tests` (compile only), installs with `./build-app.sh`, and checks the tab on screen (wide and narrow, switching tabs, window-only captures). No push, version bump or `./test.sh` until the owner says push.
