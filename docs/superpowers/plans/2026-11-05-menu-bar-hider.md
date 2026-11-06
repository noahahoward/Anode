# Menu Bar Hider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Beta Features toggle that puts two small items in the menu bar, a chevron and a divider; every icon the user has ⌘-dragged to the left of the divider disappears when the bar is collapsed and slides back when the chevron is clicked, then hides again by itself.

**Architecture:** The divider is an `NSStatusItem` whose length is made enormous when collapsed, which pushes every item to its left off the end of the bar (the method Hidden Bar uses; no permission needed). A pure model decides collapsed/expanded and when to re-collapse; a pure check refuses to collapse if any of Anode's *own* icons would be hidden; a controller takes the status items and the clock as injected dependencies so the state machine is tested with fakes. **Task 1 is a measured go/no-go: the whole approach rests on an unverified premise on macOS 27.**

**Tech Stack:** Swift 5.9, AppKit (`NSStatusBar`), XCTest (`Tests/PowerKitTests`). No private API.

**Spec:** the owner's backlog entry "menu bar widget hider/expander (hide/collapse menu bar items, expand on demand — Bartender/Ice style)", queued 2026-10-30. Behaviour of Bartender, Ice and Hidden Bar is reference only; no code is copied. Decisions beyond that entry are marked *(author's call)*.

## Global Constraints

- Beta Features section "Menu Bar Hider", **off by default** (setting `menuBarHiderEnabled`). While off: no status items, no timers, no monitors.
- Two status items, autosave names **`dev.anode.hider.divider`** and **`dev.anode.hider.toggle`**, created toggle first, then divider, because the system inserts a new item to the left of existing ones, so the divider lands left of the toggle and everything hidden is left of the divider (Task 1 confirms the real order; correct this line and Task 4 if it differs).
- The toggle is a chevron button: left-click toggles, right-click/Control-click opens a small menu (Hide/Show icons, "Hide again after" 5 s / 10 s / 30 s / Never, Open Beta Features…). Right-click must also be caught by a local event monitor, because a right click was measured not to reach a status item's action on this macOS (see `KeepAwakeController.applyEnabled`).
- Auto re-collapse delay: setting `menuBarHiderRevealSeconds`, **0 = never**, range 0–60, default **10** *(author's call)*.
- Collapsed divider length is the constant `MenuBarHider.collapsedLength`, **whatever Task 1 measures works** (expected 10000 pt); expanded divider length is the system's variable length showing a thin "│".
- **Never hide Anode's own icons.** If any Anode status item (menu bar widgets, Keep Awake) sits left of the divider, collapsing is refused and the section says which one and what to do. Never judged during full screen or within 8 s of a Space change (reuse `ScreenState.anyScreenShowsFullScreenWindow()` and the same rule as `MenuBarWidgetController.lookIsMeaningful`).
- A start-up expanded for 1 s then collapsed is *not* wanted: the bar starts **collapsed** on launch once the safety check passes.
- Toggle command `menubar.toggle`, default **⌃⌥⌘B** *(author's call)*, via `ShortcutStore`/`KeybindCenter`.
- Quitting or crashing Anode must restore the bar: status items die with the process (verified in Task 6).
- Package target stays macOS 13. New branch `menu-bar-hider` off `main`; never commit to `main`. Test command: `swift test --filter <TestClass>`.
- The owner is using the Mac: automated tests never create a real `NSStatusItem`; the real thing is exercised in Tasks 1 and 6, when the owner says so, because it moves their menu bar.
- Last step: `./build-app.sh`, confirm `BSSourceCommit` equals `git rev-parse --short HEAD` and the running process's inode matches the installed binary.

## Review Focus

- One of Anode's own icons (a widget, the Keep Awake icon) ⌘-dragged to the left of the divider: collapse refused, nothing of Anode's disappears, the reason is shown. (Tasks 3, 4)
- Display plugged/unplugged, Space change, or full screen entered while collapsed: no "your icons are hidden" false alarm, no stuck collapsed state with no way back. (Task 4)
- Feature switched off while collapsed: both items removed and every icon is back at once. (Task 4)
- Click the chevron many times quickly, and the re-collapse timer firing during a click: ends in a consistent state, one timer. (Task 2)
- A Mac with more icons than fit when expanded (14" with the notch): the reveal cannot show them all; the section must say so rather than look broken. (Tasks 1, 5)

## File Structure

| File | Responsibility |
|---|---|
| `Sources/PowerKit/Settings.swift` (modify) | `menuBarHiderEnabled`, `menuBarHiderRevealSeconds` |
| `Sources/PowerKit/MenuBarHiderModel.swift` (create) | pure state: collapsed/expanded, toggle, re-collapse deadline, the at-risk check |
| `Sources/AnodeApp/MenuBarHider.swift` (create) | controller + `HiderItems` protocol + real `StatusBarHiderItems` |
| `Sources/AnodeApp/Shortcuts.swift` (modify) | `ShortcutCommands.menuBar` added to `all` |
| `Sources/AnodeApp/BetaFeaturesWindow.swift` (modify) | `MenuBarHiderFeature` section, added to the list in `init` |
| `Sources/AnodeApp/main.swift` (modify) | construct the controller beside `keepAwake` (~line 321) |
| `Tests/PowerKitTests/MenuBarHiderSettingsTests.swift`, `MenuBarHiderModelTests.swift`, `MenuBarHiderTests.swift`, `MenuBarHiderFeatureTests.swift` (create) | tests per task |

---

### Task 1: Spike, go / no-go (owner present)

**Files:** a probe in the session scratchpad only; findings recorded in this file under "Measured".

- [ ] **Step 1: Ask the owner** for ten seconds of a disturbed menu bar. Do not run otherwise.
- [ ] **Step 2: Write a tiny AppKit probe** (scratchpad, not the repo) that creates `autosaveName "probe.divider"` with length 24, waits 3 s, sets `length = 10000`, waits 5 s, sets it back, exits. Record the on-screen frames of every status window (`CGWindowListCopyWindowInfo`, layer 25, name/owner/`kCGWindowBounds`/`kCGWindowIsOnscreen`) at each stage.
- [ ] **Step 3: Decide.** GO if, collapsed, the items left of the probe have `IsOnscreen == 0` or bounds outside the display, the items right of it are unchanged, and restoring the length brings them back. Also record: where the probe item first lands relative to Anode's widgets (fixes the order in Global Constraints); whether a ⌘-drag position persists across relaunch; what happens on the notched built-in display (items pushed under the notch vs removed).
- [ ] **Step 4: If NO-GO, stop.** Report the measurements to the owner; the alternative (Ice-style: capture the hidden icons and show them in a second bar, needs Screen Recording and synthesized clicks) is a different plan and the owner's call.
- [ ] **Step 5: Record** the measured constants (`collapsedLength`, creation order) here and commit "Menu bar hider: spike results".

### Task 2: Settings and the pure model

**Files:**
- Modify: `Sources/PowerKit/Settings.swift` (follow `keepAwakeEnabled` at each of its six spots; the reveal seconds follow `lidGlassIdleHz`)
- Create: `Sources/PowerKit/MenuBarHiderModel.swift`
- Test: `Tests/PowerKitTests/MenuBarHiderSettingsTests.swift`, `Tests/PowerKitTests/MenuBarHiderModelTests.swift`

**Interfaces:**
- Produces: `settings.menuBarHiderEnabled: Bool` (default false); `settings.menuBarHiderRevealSeconds: Double` (default 10, clamped 0...60); `enum HiderState: Equatable { case collapsed, expanded }`; `struct MenuBarHiderModel { init(revealSeconds: Double); private(set) var state: HiderState; var revealSeconds: Double; mutating func toggle(now: Date); mutating func collapse(); func recollapseDeadline() -> Date?; func shouldRecollapse(now: Date) -> Bool }`; `static func itemsAtRisk(dividerMinX: CGFloat, ownItemFrames: [NSRect]) -> [NSRect]` on `MenuBarHiderModel`.

- [ ] **Step 1: Write the failing tests.** Settings: defaults, clamping 0...60 (−5 → 0, 90 → 60), persistence, observer fires once per real change. Model: starts `.collapsed`; `toggle` flips; expanded with `revealSeconds: 10` has `recollapseDeadline == expandedAt + 10`; `shouldRecollapse` false at +9.9 s, true at +10 s; `revealSeconds: 0` → no deadline, never recollapses; toggling again resets the deadline; ten rapid `toggle` calls alternate state with one deadline; `itemsAtRisk(dividerMinX: 500, ownItemFrames: [x 100..120, x 600..640])` returns only the first; an item straddling the divider (minX 490, maxX 530) counts as at risk; empty input → `[]`.
- [ ] **Step 2: Run** `swift test --filter MenuBarHiderSettingsTests` and `--filter MenuBarHiderModelTests`. Expected: FAIL.
- [ ] **Step 3: Implement** both. The model has no AppKit state beyond `NSRect` and takes `now` as a parameter (no clock inside).
- [ ] **Step 4: Run** both filters. Expected: PASS.
- [ ] **Step 5: Commit** "Menu bar hider: settings and pure model".

### Task 3: Shortcut command

**Files:**
- Modify: `Sources/AnodeApp/Shortcuts.swift`
- Test: extend `Tests/PowerKitTests/ShortcutsTests.swift`

**Interfaces:**
- Produces: `ShortcutCommands.menuBarToggle: ShortcutCommand` (id `"menubar.toggle"`, section `"Menu bar hider"`, ⌃⌥⌘B); `ShortcutCommands.menuBar: [ShortcutCommand]`, included in `ShortcutCommands.all`.

- [ ] **Step 1: Write the failing tests.** `testMenuBarToggleDefaultIsControlOptionCommandB` (label `"⌃⌥⌘B"`); the existing "default shortcuts are pairwise distinct across `all`" test (added by the keyboard-cleaner plan, or add it here if that plan has not landed) still passes.
- [ ] **Step 2: Run** `swift test --filter ShortcutsTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the command and add it to `all`.
- [ ] **Step 4: Run** the same filter. Expected: PASS.
- [ ] **Step 5: Commit** "Menu bar hider: shortcut command".

### Task 4: The controller

**Files:**
- Create: `Sources/AnodeApp/MenuBarHider.swift`
- Test: `Tests/PowerKitTests/MenuBarHiderTests.swift`

**Interfaces:**
- Consumes: `MenuBarHiderModel`, `HiderState`, `Settings.menuBarHider*` (Task 2); `ShortcutCommands.menuBarToggle`, `KeybindCenter.shared` (Task 3); `ScreenState.anyScreenShowsFullScreenWindow()`.
- Produces:
  - `protocol HiderItems: AnyObject { func show(); func remove(); func setDividerLength(_ length: CGFloat); func setToggleImage(expanded: Bool); func dividerFrame() -> NSRect?; func ownItemFrames() -> [NSRect] }`
  - `final class MenuBarHider { static weak var current: MenuBarHider?; init(settings: Settings, items: @escaping () -> HiderItems, now: @escaping () -> Date, screensSettled: @escaping () -> Bool); var state: HiderState; var blockedBy: [NSRect]; func toggle(); func expand(); func collapse(); func tick(); var pendingTimerCount: Int; var onChange: (() -> Void)? }`
  - `static let collapsedLength: CGFloat` (value from Task 1).

- [ ] **Step 1: Write the failing tests** with a `FakeHiderItems` recording calls and returning scripted frames:
  - `testEnablingCreatesItemsAndStartsCollapsed`: after `settings.menuBarHiderEnabled = true`, fake got `show()`, divider length == `collapsedLength`, `state == .collapsed`.
  - `testDisablingRemovesItemsAndRestoresNothingHidden`: `remove()` called once; no timer pending.
  - `testToggleExpandsThenRecollapsesAfterTheDelay`: inject `now`; `toggle()` → divider short; advance 10 s, call `tick()` → collapsed again.
  - `testCollapseRefusedWhenAnOwnIconIsLeftOfTheDivider`: scripted frames put one own item left; `collapse()` leaves the divider short, `blockedBy.count == 1`, `onChange` fired.
  - `testNoJudgingWhileScreensAreUnsettled`: `screensSettled` false → the safety check is not run and the state is not changed by it.
  - `testRevealSecondsZeroNeverRecollapses`.
  - `testRapidTogglesLeaveOneTimer` (timer count exposed as `pendingTimerCount` for tests).
  - `testToggleShortcutRegisteredOnlyWhileEnabled`: via a recording registrar closure.
- [ ] **Step 2: Run** `swift test --filter MenuBarHiderTests`. Expected: FAIL.
- [ ] **Step 3: Implement `MenuBarHider`** (main thread). The real `StatusBarHiderItems` (same file) creates the two `NSStatusItem`s in the Task 1 order with the autosave names in Global Constraints, sets `isVisible = true` every time (macOS persists visibility per autosave name, see the comment in `MenuBarWidgetController.rebuild`), `sendAction(on: [.leftMouseUp, .rightMouseUp])`, adds the right-click local monitor, and finds Anode's own item windows as `NSApp.windows` whose class is `NSStatusBarWindow`, excluding its own two. A 1 s `Timer` exists **only while expanded with a non-zero delay**.
- [ ] **Step 4: Run** the same filter. Expected: PASS. `swift build` clean.
- [ ] **Step 5: Commit** "Menu bar hider: controller".

### Task 5: Beta Features section and wiring

**Files:**
- Modify: `Sources/AnodeApp/BetaFeaturesWindow.swift` (`MenuBarHiderFeature` after the last feature; add to `init` list), `Sources/AnodeApp/main.swift`
- Test: `Tests/PowerKitTests/MenuBarHiderFeatureTests.swift`

**Interfaces:**
- Consumes: `MenuBarHider.current`, `Settings.menuBarHider*`.
- Produces: `final class MenuBarHiderFeature: BetaFeature` with `enableCheckbox`, `delayPopUp`, `stateLabel`, `helpLabel`.

- [ ] **Step 1: Write the failing tests** (the shape of `KeepAwakeUITests`): checkbox writes the setting; the pop-up offers Never/5 s/10 s/30 s and writes `menuBarHiderRevealSeconds` (0/5/10/30); while off, `stateLabel` and the pop-up are hidden; when `blockedBy` is non-empty `stateLabel` says one of Anode's own icons is on the hidden side and to ⌘-drag it right of the divider; `helpLabel` always contains "Hold ⌘ and drag".
- [ ] **Step 2: Run** `swift test --filter MenuBarHiderFeatureTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the section and construct `MenuBarHider` in `main.swift`. Summary text: "Adds a chevron and a divider to the menu bar. Hold ⌘ and drag icons to the left of the divider to hide them; click the chevron to bring them back for a moment. On a Mac with a notch there is only so much room, so a long row of icons may not all fit when shown."
- [ ] **Step 4: Run** the class plus `swift test --filter BetaLayoutTests`. Expected: PASS.
- [ ] **Step 5: Commit** "Menu bar hider: Beta Features section".

### Task 6: On-hardware verification (only when the owner says so)

**Files:** none; record findings under "Measured" in this file.

- [ ] **Step 1: Build and install** (`./build-app.sh`). Owner turns the section on. Expected: the chevron and divider appear; nothing hides yet (nothing is left of the divider).
- [ ] **Step 2: Owner ⌘-drags** one non-Anode icon (e.g. Rectangle's or Todoist's) left of the divider. Expected: it vanishes after the first collapse; clicking the chevron brings it back; it re-hides after the chosen delay.
- [ ] **Step 3: Safety.** Owner ⌘-drags an Anode widget left of the divider. Expected: collapse refused, message names the problem; dragging it back clears the message. Confirm with `System Events` AX (`help of` each item of `menu bar 2`) that the Anode widgets are all still present.
- [ ] **Step 4: Restore.** Turn the section off (every icon returns), turn on, `kill -9 $(pgrep -x AnodeApp)` while collapsed (every icon returns), relaunch. Expected: the hider returns collapsed and the hidden icon is still on the hidden side.
- [ ] **Step 5: Displays and Spaces.** Plug/unplug the external display and enter/leave a full-screen app while collapsed. Expected: no false "blocked" message, no stuck state; the placement logic of the Anode widgets (`Density`) is unchanged: compare `MenuBarWidgetController.debugDump` before and after.
- [ ] **Step 6: Record** the results (including how many icons fit on the notched display when expanded) and commit "Menu bar hider: verified on hardware".
