# Keyboard & Screen Cleaner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Beta Features section whose button (and optional shortcut) turns every display pure black, swallows all keyboard, mouse and trackpad input so the keyboard and screen can be wiped, and shows the key combination that ends it in the bottom-left corner.

**Architecture:** A pure `CleanerInputFilter` decides, per event, what to swallow and when the exit combination has been pressed. An active event tap (all event types) feeds it from `EventTapThread` and hands "exit" to the main thread. A controller owns one borderless black window per display plus an idle-sleep hold, and takes the tap, the windows and the hold as injected dependencies so the whole session is tested with fakes. No Accessibility means no session at all: a black window that lets keystrokes through to the app underneath is worse than nothing.

**Tech Stack:** Swift 5.9, AppKit, CoreGraphics event taps, IOKit power assertions (existing `SleepAssertions`), XCTest (`Tests/PowerKitTests`).

**Spec:** the owner's brief of 2026-11-05 (in conversation; no separate spec file): "pure black window that takes inputs, keyboard shortcut combo in the bottom left of the window to show how to exit". The decisions this plan adds on top are in Global Constraints and marked *(author's call)*.

## Global Constraints

- Beta Features section titled "Keyboard & Screen Cleaner". **Nothing runs until a session starts**: no tap, no window, no timer, no assertion before. Section is available whether or not any checkbox is on.
- The screen is **pure black** (`NSColor.black`, alpha 1) on **every** display, covering the full `screen.frame` (menu bar and Dock included), at level `NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))`, joining all Spaces.
- The exit combination is shown **bottom-left** of the window on each display, in secondary-white text on the black, as `Shortcut.label` text ("Press ⌃⌥⌘⎋ to finish"). *(copy: author's call)*
- Default exit combination **⌃⌥⌘⎋** (Control-Option-Command-Escape) *(author's call: four keys together do not happen while wiping)*; remappable via the existing `ShortcutStore`/Shortcuts window. Default start shortcut **⌃⌥⌘K** *(author's call; unused by every existing default)*, active only while the setting `keyboardCleanerShortcutEnabled` is on (default **false**).
- Every event is swallowed except: (a) the exit combination (consumed, ends the session), (b) a key-up for a key that was already down when the session began, which passes so no app is left believing a key is held.
- Requires Accessibility (`AccessibilityAccess.isTrusted`). Without it the section says so, shows the existing "Open Accessibility Settings…" button, and **Start does nothing else**.
- The Mac must not dim or sleep the display during a session: hold `SleepAssertions` for the session and release it at the end.
- If the system disables the tap (`tapDisabledByTimeout`/`ByUserInput`), the session **ends**, never silently carries on with input flowing.
- Process death must leave nothing behind: tap, windows and assertion all die with the process (verified in Task 6, not assumed).
- Package target stays macOS 13; no new dependency. Work on a new branch `keyboard-cleaner` off `main`; never commit to `main`. Test command: `swift test --filter <TestClass>`.
- The owner is using the Mac: automated tests must never install a real tap, show a real window, or swallow real input. The real thing is exercised only in Task 6, when the owner says so.
- After the last task, `./build-app.sh` and confirm `BSSourceCommit` in `~/Applications/Anode.app/Contents/Info.plist` equals `git rev-parse --short HEAD` and the running process's inode matches the installed binary (standing instruction: rebuild after every change).

## Review Focus

- A key held when the session starts (the Command of the start shortcut): its key-up must reach the system exactly once; no stuck modifier afterwards. (Task 1)
- Exit combination pressed with extra keys or in a different modifier order: it must still end the session only when exactly those modifiers + key are down; ⌃⌥⌘ + another key must not. (Task 1)
- A display is plugged in, unplugged or re-arranged mid-session: every display is black, none is left bare, nothing is stranded behind a stale window. (Task 3)
- Accessibility revoked mid-session or the tap disabled by the system: the session ends and the windows go away within one tick. (Task 3)
- Start pressed twice (button then shortcut), or the exit combination mashed: one session, one tear-down, assertion released once. (Task 3)

## File Structure

| File | Responsibility |
|---|---|
| `Sources/PowerKit/Settings.swift` (modify) | setting `keyboardCleanerShortcutEnabled` |
| `Sources/AnodeApp/CleanerInputFilter.swift` (create) | pure decision per event: swallow / pass / exit; tracks keys held at start |
| `Sources/AnodeApp/CleanerInputTap.swift` (create) | `CleanerInputTapping` protocol + real all-events tap on `EventTapThread` |
| `Sources/AnodeApp/CleanerWindows.swift` (create) | `CleanerWindowPresenting` protocol + real black windows with the bottom-left hint |
| `Sources/AnodeApp/KeyboardCleaner.swift` (create) | the session controller (state machine, injected dependencies) |
| `Sources/AnodeApp/Shortcuts.swift` (modify) | `ShortcutCommands.cleaner` (start, exit) added to `all` |
| `Sources/AnodeApp/BetaFeaturesWindow.swift` (modify) | `KeyboardCleanerFeature` section, added to the list in `init` |
| `Sources/AnodeApp/main.swift` (modify) | construct the controller beside `keepAwake` (line ~321) |
| `Tests/PowerKitTests/CleanerSettingsTests.swift`, `CleanerInputFilterTests.swift`, `CleanerWindowsTests.swift`, `KeyboardCleanerTests.swift`, `KeyboardCleanerFeatureTests.swift` (create) | tests per task |

---

### Task 1: The input filter (pure)

**Files:**
- Create: `Sources/AnodeApp/CleanerInputFilter.swift`
- Test: `Tests/PowerKitTests/CleanerInputFilterTests.swift`

**Interfaces:**
- Produces:
  - `struct CleanerEvent { enum Kind { case keyDown, keyUp, flagsChanged, other }; let kind: Kind; let key: Int; let flags: CGEventFlags }`
  - `enum CleanerVerdict: Equatable { case swallow, pass, exit }`
  - `final class CleanerInputFilter { init(exit: Shortcut, keysDownAtStart: Set<Int>); func verdict(for: CleanerEvent) -> CleanerVerdict }`

- [ ] **Step 1: Write the failing tests** in `CleanerInputFilterTests`:
  - `testEverythingIsSwallowedByDefault`: a `.keyDown` for `kVK_ANSI_A`, a `.keyUp`, a `.flagsChanged`, a `.other` all → `.swallow`.
  - `testExitCombinationEnds`: filter with exit `Shortcut(key: kVK_Escape, carbon: controlKey|optionKey|cmdKey)`; keyDown Escape with `[.maskControl,.maskAlternate,.maskCommand]` → `.exit`.
  - `testExitNeedsExactlyThoseModifiers`: same key with an added `.maskShift`, and with `⌃⌥` only → `.swallow`.
  - `testExitIgnoresCapsLockAndFnFlags`: flags plus `.maskAlphaShift` and `.maskSecondaryFn` → still `.exit` (uses `Shortcut.mask`).
  - `testKeyUpOfAKeyHeldAtStartPassesOnce`: `keysDownAtStart: [kVK_Command]`; `.keyUp` for it → `.pass`, a second identical `.keyUp` → `.swallow`.
  - `testKeyDownOfAHeldKeyIsStillSwallowed`: auto-repeat of a held-at-start key down → `.swallow`.
  - `testExitKeyUpIsSwallowed`: after `.exit`, the Escape `.keyUp` → `.swallow`.
- [ ] **Step 2: Run** `swift test --filter CleanerInputFilterTests`. Expected: FAIL, type not defined.
- [ ] **Step 3: Implement `CleanerInputFilter`** in `CleanerInputFilter.swift`. Reuse `Shortcut.matches(key:flags:)`; the filter is a value-holding class with a lock-free single-thread contract (called only on the tap thread; document it).
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Commit** `git add Sources/AnodeApp/CleanerInputFilter.swift Tests/PowerKitTests/CleanerInputFilterTests.swift && git commit -m "Keyboard cleaner: pure input filter"`.

### Task 2: Setting and shortcut commands

**Files:**
- Modify: `Sources/PowerKit/Settings.swift` (keys ~line 44, defaults ~114, `Values` ~223, accessor ~439, change notification ~812, read ~963; follow `keepAwakeEnabled` at each spot)
- Modify: `Sources/AnodeApp/Shortcuts.swift` (`ShortcutCommands`)
- Test: `Tests/PowerKitTests/CleanerSettingsTests.swift`; extend `Tests/PowerKitTests/ShortcutsTests.swift`

**Interfaces:**
- Produces: `Settings.Key.keyboardCleanerShortcutEnabled`, `settings.keyboardCleanerShortcutEnabled: Bool` (default `false`); `ShortcutCommands.cleanerStart` and `ShortcutCommands.cleanerExit` (both `ShortcutCommand`, ids `"cleaner.start"` / `"cleaner.exit"`, section `"Keyboard & Screen Cleaner"`, defaults ⌃⌥⌘K and ⌃⌥⌘⎋), and `ShortcutCommands.cleaner: [ShortcutCommand]` included in `ShortcutCommands.all`.

- [ ] **Step 1: Write the failing tests.** `CleanerSettingsTests`: default is false; true persists across `Settings(defaults:)` handles; observer fires once per real change (copy the shape of `LidGlassSettingsTests`). `ShortcutsTests`: `testCleanerCommandsHaveTheDocumentedDefaults` asserts both defaults via `Shortcut.label` == `"⌃⌥⌘K"` and `"⌃⌥⌘⎋"`; `testNoDefaultShortcutIsSharedAcrossAllCommands` asserts `ShortcutCommands.all` default shortcuts are pairwise distinct.
- [ ] **Step 2: Run** `swift test --filter CleanerSettingsTests` and `--filter ShortcutsTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the setting at each of the six spots and the two commands.
- [ ] **Step 4: Run** both filters. Expected: PASS (and the pre-existing shortcut tests still pass).
- [ ] **Step 5: Commit** the five files, message "Keyboard cleaner: setting and shortcut commands".

### Task 3: The session controller

**Files:**
- Create: `Sources/AnodeApp/KeyboardCleaner.swift`
- Test: `Tests/PowerKitTests/KeyboardCleanerTests.swift`

**Interfaces:**
- Consumes: `CleanerInputFilter`, `CleanerEvent`, `CleanerVerdict` (Task 1); `Settings.keyboardCleanerShortcutEnabled`, `ShortcutCommands.cleanerStart/Exit`, `ShortcutStore.shared.shortcut(for:)` (Task 2); `SleepAssertions` (PowerKit); `AccessibilityAccess.isTrusted`; `KeybindCenter.shared.register(owner:commands:handler:)`.
- Produces:
  - `protocol CleanerInputTapping: AnyObject { func start(filter: CleanerInputFilter, onExit: @escaping () -> Void, onDisabled: @escaping () -> Void) -> Bool; func stop() }`
  - `protocol CleanerWindowPresenting: AnyObject { func show(hint: String, on screens: [NSScreen]); func hide(); var isShowing: Bool { get } }`
  - `final class KeyboardCleaner { static weak var current: KeyboardCleaner?; init(settings: Settings, store: ShortcutStore, tap: CleanerInputTapping, windows: CleanerWindowPresenting, assertions: SleepAssertions, isTrusted: @escaping () -> Bool, screens: @escaping () -> [NSScreen], keysDown: @escaping () -> Set<Int>); var isActive: Bool; func start() -> StartResult; func stop(); func screensChanged(); func tick(); var onChange: (() -> Void)? }` with `enum StartResult: Equatable { case started, alreadyRunning, needsAccessibility, tapUnavailable }`.

- [ ] **Step 1: Write the failing tests** with fakes for tap/windows/assertions (fakes live in the test file):
  - `testStartWithoutAccessibilityDoesNothing`: returns `.needsAccessibility`; fake tap, windows, assertions untouched.
  - `testStartShowsWindowsHoldsAssertionAndTapsWithTheStoredExitCombination`: windows hint contains `"⌃⌥⌘⎋"`; the tap received a filter whose exit matches the store's current exit shortcut; `keysDown()` result passed as `keysDownAtStart`.
  - `testTapFailingToStartUndoesEverything`: fake tap returns false → `.tapUnavailable`, windows hidden, assertion released, `isActive == false`.
  - `testExitCallbackEndsTheSession`: fire `onExit` → windows hidden, tap stopped, assertion released once, `onChange` called.
  - `testTapDisabledEndsTheSession`: fire `onDisabled` → same tear-down.
  - `testStartTwiceIsOneSession`: second call `.alreadyRunning`; tap `start` count 1.
  - `testStopTwiceReleasesOnce`.
  - `testRemappedExitShortcutIsShownAndUsed`: assign another exit shortcut in a test `ShortcutStore`; hint shows it.
  - `testScreenChangeRebuildsWindows`: call `controller.screensChanged()` with a new screens array → `windows.show` called again with it, no second tap start.
  - `testAccessibilityRevokedAtTick`: `controller.tick()` with `isTrusted` now false → session ends.
- [ ] **Step 2: Run** `swift test --filter KeyboardCleanerTests`. Expected: FAIL.
- [ ] **Step 3: Implement `KeyboardCleaner`.** Main-thread only. `start()` order: check trust → build filter from `store.shortcut(for: .cleanerExit)` (fall back to the default if the user cleared it) → `windows.show` → `tap.start` (on failure `windows.hide`, return `.tapUnavailable`) → `assertions.hold(reason: "Anode keyboard cleaner")`. Observes `NSApplication.didChangeScreenParametersNotification` and `NSWorkspace.didWakeNotification` → `screensChanged()`; a 1 s `Timer` runs **only while a session is active** and calls `tick()`. When `settings.keyboardCleanerShortcutEnabled` is on, registers `cleanerStart` with `KeybindCenter`; unregisters when off.
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Commit** the two files, message "Keyboard cleaner: session controller".

### Task 4: The real tap

**Files:**
- Create: `Sources/AnodeApp/CleanerInputTap.swift`
- Test: extend `Tests/PowerKitTests/CleanerInputFilterTests.swift` (the pure mapping only; the tap itself is exercised in Task 6)

**Interfaces:**
- Consumes: `CleanerInputTapping`, `CleanerEvent`, `CleanerInputFilter` (Tasks 1, 3); `EventTapThread.shared`, `TapPortBox`.
- Produces: `final class CleanerInputTap: CleanerInputTapping`; `static func event(from type: CGEventType, _ cg: CGEvent) -> CleanerEvent` (pure given its inputs).

- [ ] **Step 1: Write the failing test** `testTypeMapping`: `.keyDown/.keyUp/.flagsChanged` map to their `Kind` with the key code and flags read from a `CGEvent(keyboardEventSource:virtualKey:keyDown:)`; `.mouseMoved`, `.scrollWheel` and raw type 29 map to `.other`.
- [ ] **Step 2: Run** `swift test --filter CleanerInputFilterTests/testTypeMapping`. Expected: FAIL.
- [ ] **Step 3: Implement `CleanerInputTap`.** `CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask(~0), ...)`, run-loop source added via `EventTapThread.shared.add`; the callback returns `nil` for `.swallow`/`.exit` and the event for `.pass`; `.exit` calls `onExit` on the main queue exactly once; `tapDisabledByTimeout`/`tapDisabledByUserInput` call `onDisabled` on the main queue (do **not** re-enable). `stop()` disables the tap, removes the source, invalidates the port; idempotent.
- [ ] **Step 4: Run** the filter-tests class. Expected: PASS. `swift build` clean.
- [ ] **Step 5: Commit** the two files, message "Keyboard cleaner: all-events tap".

### Task 5: The windows and the Beta Features section

**Files:**
- Create: `Sources/AnodeApp/CleanerWindows.swift`
- Modify: `Sources/AnodeApp/BetaFeaturesWindow.swift` (new `KeyboardCleanerFeature` after `KeepAwakeFeature`; add to `init` list at line 50-52), `Sources/AnodeApp/main.swift` (~321), `Sources/AnodeApp/ShortcutsWindow.swift` only if the window lists sections from a hard-coded array (read it first; add the cleaner section if so)
- Test: `Tests/PowerKitTests/CleanerWindowsTests.swift`, `Tests/PowerKitTests/KeyboardCleanerFeatureTests.swift`

**Interfaces:**
- Consumes: `CleanerWindowPresenting`, `KeyboardCleaner` (Task 3), `BetaFeature`.
- Produces: `final class CleanerWindows: CleanerWindowPresenting`; `static func frames(for screens: [NSRect]) -> [NSRect]` (pure); `static func hintOrigin(in frame: NSRect, hintSize: NSSize) -> NSPoint` (bottom-left with a 24 pt margin); `final class KeyboardCleanerFeature: BetaFeature` with `startButton`, `shortcutCheckbox`, `statusLabel`, `accessButton`.

- [ ] **Step 1: Write the failing tests.** `CleanerWindowsTests`: `testOneFramePerScreenCoveringItExactly`; `testHintSitsBottomLeftWithMargin24` (origin == `(frame.minX + 24, frame.minY + 24)`); `testWindowIsBlackOpaqueAndAboveTheMenuBar` using a real `CleanerWindows.makeWindow(for:)` that is **never ordered front** (assert `backgroundColor == .black`, `isOpaque`, `level.rawValue >= Int(CGShieldingWindowLevel())`, `collectionBehavior` contains `.canJoinAllSpaces` and `.stationary`, `ignoresMouseEvents == false`). `KeyboardCleanerFeatureTests` (the shape of `KeepAwakeUITests`, with a fake-backed controller): Start button calls `start()`; with no Accessibility the status label says Accessibility is needed, `accessButton` is visible and Start does not start; the checkbox writes `keyboardCleanerShortcutEnabled`; the section lists both shortcut labels from the store.
- [ ] **Step 2: Run** both classes. Expected: FAIL.
- [ ] **Step 3: Implement** `CleanerWindows` (borderless `NSWindow` subclass overriding `canBecomeKey`/`canBecomeMain` to true so the hint renders; `animationBehavior = .none`; `hasShadow = false`; hide the pointer with `NSCursor.hide()` on show and `NSCursor.unhide()` on hide, balanced exactly once each, since the tap already freezes the pointer and a visible frozen arrow reads as broken) and `KeyboardCleanerFeature`; summary text: "Turns every screen black and ignores the keyboard, mouse and trackpad so you can wipe them. The combination shown in the bottom-left corner ends it. Needs Accessibility." Construct `KeyboardCleaner` in `main.swift` and assign `KeyboardCleaner.current`.
- [ ] **Step 4: Run** both classes plus `swift test --filter BetaLayoutTests` (the window's column layout must still fit). Expected: PASS.
- [ ] **Step 5: Commit** all touched files, message "Keyboard cleaner: windows and Beta Features section".

### Task 6: On-hardware verification (only when the owner says so)

**Files:** none (probes live in the session scratchpad; record findings in `docs/superpowers/plans/2026-11-05-keyboard-cleaner.md` under a "Measured" heading)

- [ ] **Step 1: Ask the owner** to be ready: the screen goes black and the keyboard/trackpad go dead until the combination is pressed. Do not start otherwise.
- [ ] **Step 2: Build and install** (`./build-app.sh`), then have the owner press Start in Beta Features → Keyboard & Screen Cleaner. Owner confirms by eye: black on every display, hint bottom-left, pointer does not move, typing goes nowhere (a TextEdit window left open behind stays empty), four-finger swipe / Mission Control key / hot corners do nothing, Caps Lock and brightness keys do nothing harmful.
- [ ] **Step 3: Owner presses the exit combination.** Expected: everything returns within one frame; no stuck modifier (type a few characters, check Shift/Command behave).
- [ ] **Step 4: Kill test.** The keyboard is dead during a session, so arm the kill first: in Terminal run `(sleep 20; kill -9 $(pgrep -x AnodeApp)) &`, then start a session. Expected: after 20 s the black windows and the tap vanish with the process and input works again. If anything stays, add a launch-time cleanup to `KeyboardCleaner.init` and re-test.
- [ ] **Step 5: Display test.** Start a session, unplug/plug the external display. Expected: both displays black at all times.
- [ ] **Step 6: Idle test.** Start a session and leave it longer than the display-sleep setting. Expected: the display does not sleep; after the exit the assertion is gone (`pmset -g assertions` has no "Anode keyboard cleaner").
- [ ] **Step 7: Record** what was measured (and anything that differed from the plan) in this file, then commit "Keyboard cleaner: verified on hardware".

## Measured

2026-11-06, owner on the installed build (9bf2b03): "keyboard cleaner works well." The owner did not itemize Task 6's steps, so only the overall result is recorded; the kill test (Step 4), display plug/unplug (Step 5) and the idle/`pmset` check (Step 6) were not reported separately and remain unconfirmed.
