# Sound Menu, Exact Copy (step 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Anode's own Sound item in the menu bar opens a menu that is a pixel-exact, fully working copy of macOS 27's
Sound menu. There is nothing of Anode's in it yet: per-app volume is step 2 and has its own plan.

**Architecture:** The menu is drawn by Anode from a model.
- **Pure (PowerKit, unit-tested):** the model and everything that decides: parsing Apple's panel, AirPods battery,
  icon choice, layout numbers, the press/refusal state machine.
- **Live (AnodeApp, behind protocols, verified on hardware):** Core Audio (outputs, volume), IOKit (accessory
  batteries), and a `SystemPanelDriver` that opens Apple's Sound panel off the screen through Accessibility to read and
  press the rows only Apple can drive (listening mode, Spatial Audio, Conversation Awareness, AirPlay receivers).

**Tech Stack:** Swift, AppKit (`NSStatusItem`, a borderless non-activating `NSPanel`, the glass material Task 1 picks),
CoreAudio, IOKit power sources, ApplicationServices (AX), XCTest in `Tests/PowerKitTests`.

**Spec:** `docs/superpowers/specs/2026-11-15-sound-and-battery-menus-design.md` (steps 1 of 4; read "What only Apple's
own panel can do", "Calls made from the builder check" and "Owner's answers" before any task).

## Global Constraints

- Beta Features section "Sound Menu", **off by default**, setting `soundMenuEnabled` (`com.anode.settings`). While off:
  no status item, no AX observer, no Core Audio listener, no timer.
- **Exact means measured:** captures of Apple's panel and Anode's over the same background, overlaid; every row, glyph,
  font, colour and spacing matches. Judging by eye doesn't count. Both light and dark appearance.
- **Never on screen:** no Apple window may be visible because Anode used it. Every new `com.apple.controlcenter` window
  (panel and alerts) is moved to x = -4000 the moment it is created, and again once it is found (Apple reuses
  windows). Apple's panel is closed after every use, and no window of it may be left.
- **Never remove or hide Apple's icon.** Anode works with it present (press `com.apple.menuextra.sound`) or removed
  (Control Center item, then its `controlcenter-volume` button). Removing it is the person's choice.
- **Read after press ≥ 1.0 s** (`SystemPanelTiming.settleAfterPress = 1.0`); 0.4 s read stale.
- A refusal alert from Apple is pressed OK at once, its text shown as one line in Anode's menu, and the checkmark goes
  back. Where Anode knows Apple would refuse, it does not press: **Adaptive needs both AirPods present**
  (Left and Right both in the accessory batteries).
- **No known bugs in a release (owner).** Anything found that would ship as a known bug is fixed or the release waits for
  the owner.
- No other product's name in code, UI, tests, commits. Tests use neutral device names ("Test AirPods Pro",
  "Living Room Speaker"), never the owner's.
- Tests never touch real settings (`TestDefaults`), the real menu bar, Apple's panel, real audio or real power state.
- Branch `sound-battery-menus`. Test command: `swift test --filter <TestClass>`; before any push `./test.sh --quick`.
  Install with `./build-app.sh` (a branch with no upstream), then check `BSSourceCommit` equals
  `git rev-parse --short HEAD` and the running inode matches. Check `pmset -g | grep SleepDisabled` before installing.
- Release rules in `CLAUDE.md` (version, CHANGELOG, UPDATE-NOTE, tag) apply when the owner says push; not before.

## Review Focus

1. **AirPods disconnect, or an AirPlay receiver appears, while the menu is open:** rows appear or go without the menu
   jumping under the pointer more than Apple's does, no stale checkmark, no crash. (Task 6 test
   `testDeviceRemovedWhileOpenDropsRowAndSelection`.)
2. **The person has Apple's own Sound menu open** when Anode needs the panel: Anode must not move the person's visible
   panel off the screen or press anything in it; it waits and retries after it closes. (Task 4 test
   `testDoesNotUseAPanelThePersonOpened`.)
3. **Accessibility revoked:** the Apple-only rows show as unavailable with one line saying why; volume, outputs and
   battery still work. (Task 6 test `testWithoutAccessibilityAppleRowsAreUnavailable`.)
4. **Apple's panel changes after a macOS update** (an id or description no longer found): the parser yields no row
   rather than a wrong one, and nothing is pressed by guess. (Task 3 test `testUnknownTreeYieldsNoAppleRows`.)
5. **A press whose result never arrives** (panel failed to open, closed early): the checkmark returns to the last value
   read and the line says it didn't take. (Task 4 test `testPressWithNoPanelRevertsAndSaysSo`.)

---

### Task 1: Spike: reference captures and the open questions (owner present)

**Files:** probes in the session scratchpad; captures in `measurements/sound-menu/` (add `measurements/sound-menu/` to
`.gitignore`: the captures show the owner's device names). Findings go in this file under "Measured".

- [ ] **Step 1: Captures of Apple's panel.** With `screencapture -l <window id> -o` (window only), capture Apple's Sound
  panel in each state this Mac can show: AirPods output and expanded; AirPods collapsed; Mac speakers output; muted;
  volume at 0, 0.33, 0.66, 1; each listening mode checked; Conversation Awareness On; hover on a device row and on a
  listening row; light and dark appearance. Capture the menu bar icon (Apple's Sound item) for speakers at each volume
  band, muted, AirPods, and pressed.
- [ ] **Step 2: Layout numbers.** From the AX frames (see the probe output in the spec) and the captures, write a table
  under "Measured": panel width and height, corner radius, insets, slider frame, heading/row/divider heights and
  y-offsets, icon circle diameter, label font (size, weight, colour per appearance), check glyph, chevron. Name every
  number as the constant it becomes in `SoundMenuMetrics` (Task 5).
- [ ] **Step 3: Material.** Build a throwaway borderless panel with each candidate (`NSGlassEffectView`, and
  `NSVisualEffectView` `.menu`/`.popover`/`.hudWindow`) at Apple's frame over the same desktop and overlay its capture on
  Apple's. Record which matches and the residual difference.
- [ ] **Step 4: The open questions from the spec**, each answered with a measurement:
  (1) with a probe `NSPanel` open, does opening Apple's panel off the screen close it, or take key focus, or activate
  Control Center; does typing in the front app get interrupted; (2) does Apple's menu bar icon show its pressed look
  while the panel is open off the screen (capture the item); (3) cost of a read on open (ms, CPU) and of keeping
  state fresh in the background (watch `kAXValueChanged`? or re-read on open only); (4) Control Center route timing
  vs direct; (5) person has Apple's panel open: how Anode can tell (window on screen at its own x) and what a press would
  do; (6) Space / full-screen behaviour; (7) is the refusal alert caught by the window-created observer before it draws.
- [ ] **Step 5: Go / no-go.** Write the decision under "Measured". **No-go conditions:** Apple's panel or its pressed
  icon is visible to the owner, or opening it closes Anode's menu with no workaround. Stop and ask the owner then.

### Task 2: Setting and the Beta Features section

**Files:**
- Modify: `Sources/PowerKit/Settings.swift` (Key, Default, snapshot, property, beside `menuBarHiderEnabled`)
- Create: `Sources/AnodeApp/SoundMenuFeature.swift`
- Modify: `Sources/AnodeApp/BetaFeaturesWindow.swift` (`defaultFeatures`: add after `MenuBarHiderFeature`)
- Test: `Tests/PowerKitTests/SoundMenuSettingsTests.swift`, `Tests/PowerKitTests/SoundMenuFeatureTests.swift`

**Interfaces:**
- Produces: `Settings.soundMenuEnabled: Bool` (default `false`); `final class SoundMenuFeature: BetaFeature`,
  `init(settings: Settings, accessibility: @escaping () -> Bool = { AXIsProcessTrusted() })`, with
  `enableCheckbox: NSButton` titled "Show Anode's Sound menu in the menu bar" and `statusLabel`.

- [ ] **Step 1: Failing tests:** `testDefaultIsOff` (`XCTAssertFalse(Settings(defaults:).soundMenuEnabled)`),
  `testPersistsAcrossHandles`; `testCheckboxWritesSetting`, `testWithoutAccessibilitySaysAppleRowsNeedIt`
  (statusLabel contains "Accessibility"), `testListedInDefaultFeatures` (a `SoundMenuFeature` is in
  `BetaFeaturesWindowController.defaultFeatures(settings:)`).
- [ ] **Step 2: Run** `swift test --filter SoundMenu` — Expected: FAIL (no such property/class).
- [ ] **Step 3: Implement.** Summary text: "Anode's own Sound menu, the same as macOS's, next to it in the menu bar. It
  works with or without macOS's Sound icon; you can remove macOS's in System Settings → Control Center. Listening mode,
  Conversation Awareness and AirPlay need Accessibility."
- [ ] **Step 4: Run** `swift test --filter SoundMenu` — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Sound Menu: setting and Beta Features section"`.

### Task 3: Pure model: Apple's panel, AirPods battery, the icon

**Files:**
- Create: `Sources/PowerKit/AXNode.swift`, `Sources/PowerKit/AppleSoundPanel.swift`,
  `Sources/PowerKit/AccessoryBattery.swift`, `Sources/PowerKit/SoundIcon.swift`
- Test: `Tests/PowerKitTests/AppleSoundPanelTests.swift`, `AccessoryBatteryTests.swift`, `SoundIconTests.swift`

**Interfaces:**
- Produces:
  - `struct AXNode: Equatable { var role, subrole, identifier, description, value: String; var enabled: Bool; var frame: CGRect; var children: [AXNode] }`
  - `struct AppleSoundPanel: Equatable { var volume: Double?; var devices: [AppleDeviceRow]; var listening: [AppleChoiceRow]; var spatial: [AppleChoiceRow]; var conversation: [AppleChoiceRow]; var symbolForDevice: [String: String] }`
    with `static func parse(_ root: AXNode) -> AppleSoundPanel`
  - `struct AppleDeviceRow: Equatable { var name: String; var isSelected: Bool; var batteryText: String? }`;
    `struct AppleChoiceRow: Equatable { var section: String; var title: String; var isOn: Bool; var enabled: Bool; var device: String }`
  - `struct AccessoryBattery: Equatable { enum Part { case left, right, case_, single }; var group: String; var part: Part; var percent: Int; var charging: Bool }`
    with `static func parse(_ sources: [[String: Any]]) -> [AccessoryBattery]` (reads `Accessory Category`,
    `Part Identifier`, `Group Identifier`, `Current Capacity`, `Is Charging`, `Type == "Accessory Source"`).
  - `enum SoundIcon { static func symbol(volume: Double, muted: Bool, output: OutputKind) -> String }`,
    `enum OutputKind { case speakers, airpodsPro, airpods, headphones, airplay, other }`

- [ ] **Step 1: Fixtures.** Turn the spec's probe dump into `AXNode` fixtures in the test file, with neutral names:
  device "Test AirPods Pro" (desc "Test AirPods Pro, 100%, 66%, 77%", selected), "MacBook Pro Speakers", "Living Room
  Speaker" and "Den TV"; listening rows Transparency=1, Adaptive=0, Noise Cancellation=0; Spatial "Not Available"
  disabled; Conversation Off=1/On=0; an `AXImage` with id `airpods.pro.gen1`.
- [ ] **Step 2: Failing tests:** `testParsesVolume` (0.5); `testParsesDevicesInOrderWithSelection`;
  `testListeningRowsBelongToTheirSection` (headings split rows: "Listening Mode", "Spatial Audio", "Conversation
  Awareness"); `testDisabledSpatialRow`; `testSymbolNameFromImage` (`symbolForDevice["Test AirPods Pro"] ==
  "airpods.pro.gen1"`); `testUnknownTreeYieldsNoAppleRows` (a tree with other ids → empty arrays, volume nil);
  `testBatteryPartsFromPowerSources` (Left 100 charging, Right 64, Case 77; the internal battery entry ignored);
  `testBothBudsPresent` helper `AccessoryBattery.bothBudsPresent(in:group:) -> Bool`; `testIconBands` (0 → muted-look
  symbol; Apple's thresholds from Task 1 "Measured"; AirPods output → the AirPods symbol).
- [ ] **Step 3: Run** `swift test --filter "AppleSoundPanel|AccessoryBattery|SoundIcon"` — Expected: FAIL.
- [ ] **Step 4: Implement.** Sections are assigned by the nearest preceding `AXHeading`; device rows are
  `AXCheckBox` whose id starts with `sound-device-` and which are not under a heading of their own device's section.
- [ ] **Step 5: Run** the same filter — Expected: PASS.
- [ ] **Step 6: Commit** `git commit -m "Sound Menu: model of Apple's panel, accessory batteries, icon"`.

### Task 4: The system panel driver

**Files:**
- Create: `Sources/PowerKit/SystemPanelPress.swift` (pure state machine), `Sources/AnodeApp/SystemPanelDriver.swift`
  (live AX)
- Test: `Tests/PowerKitTests/SystemPanelPressTests.swift`

**Interfaces:**
- Consumes: `AXNode`, `AppleSoundPanel` (Task 3).
- Produces:
  - `protocol SystemPanelDriving: AnyObject { func read(_ panel: SystemPanelKind, done: @escaping (Result<AXNode, SystemPanelError>) -> Void); func press(_ panel: SystemPanelKind, row: SystemPanelRow, done: @escaping (SystemPanelOutcome) -> Void) }`
  - `enum SystemPanelKind { case sound, battery }`; `struct SystemPanelRow: Equatable { var identifier: String; var description: String }`
  - `enum SystemPanelOutcome: Equatable { case done(AXNode), refused(String), failed(SystemPanelError) }`
  - `enum SystemPanelError: Error, Equatable { case noAccessibility, noMenuExtra, panelDidNotOpen, rowNotFound, personHasItOpen }`
  - `enum SystemPanelTiming { static let settleAfterPress = 1.0; static let openTimeout = 1.0 }`
  - `struct SystemPanelPress` (pure): given events (opened, moved, rowFound, pressed, alert(text), settled(tree),
    closed, timeout) → next action and final outcome.

- [ ] **Step 1: Failing tests (pure):** `testHappyPathOpensMovesPressesSettlesCloses` (action order: openOffScreen,
  pressRow, waitSettle 1.0, read, close; outcome `.done`); `testAlertIsDismissedAndReported` (alert "Failed to set
  listening mode / Put … in both ears…" → actions include `dismissAlert`, outcome `.refused(<both lines>)`);
  `testPressWithNoPanelRevertsAndSaysSo` (timeout before opened → `.failed(.panelDidNotOpen)`, close still issued);
  `testDoesNotUseAPanelThePersonOpened` (panel already on screen at its own x before Anode opened it →
  `.failed(.personHasItOpen)`, no press, no move); `testRouteFallsBackToControlCenter` (no sound menu extra → actions
  start with openControlCenter, pressSoundButton).
- [ ] **Step 2: Run** `swift test --filter SystemPanelPress` — Expected: FAIL.
- [ ] **Step 3: Implement** `SystemPanelPress` and the live `SystemPanelDriver` that carries out its actions: find
  `com.apple.MenuBarAgent`'s `AXExtrasMenuBar` item by id; one `AXObserver` for `kAXWindowCreatedNotification` on the
  `com.apple.controlcenter` pid that moves every new window to (-4000, its y) and also re-sets the position once the
  window is found; read with a depth limit of 16; press by matching both identifier and description; close by pressing
  the item again; verify no Control Center window remains, otherwise press the item once more. Serialize all work on one
  queue; one panel use at a time. The live driver has no unit test; it is verified in Task 8.
- [ ] **Step 4: Run** `swift test --filter SystemPanelPress` — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Sound Menu: drive Apple's panel off the screen"`.

### Task 5: Audio outputs and the layout

**Files:**
- Create: `Sources/AnodeApp/AudioOutputs.swift` (live Core Audio + IOPS), `Sources/PowerKit/SoundMenuMetrics.swift`,
  `Sources/PowerKit/SoundMenuLayout.swift`
- Test: `Tests/PowerKitTests/SoundMenuLayoutTests.swift`

**Interfaces:**
- Produces:
  - `protocol AudioOutputs: AnyObject { var devices: [OutputDevice] { get }; var defaultDeviceID: String? { get }; var volume: Double { get }; var muted: Bool { get }; func setDefault(_ id: String); func setVolume(_ v: Double); var onChange: (() -> Void)? { get set } }`
  - `struct OutputDevice: Equatable { var id: String /* Core Audio UID */; var name: String; var kind: OutputKind }`
  - `func accessoryBatteries() -> [AccessoryBattery]` (live, `IOPSCopyPowerSourcesByType(0)` via `dlsym`)
  - `enum SoundMenuMetrics` — every number from Task 1 "Measured", named there.
  - `struct SoundMenuLayout { static func frames(for model: SoundMenuModel, appearance: Appearance) -> [LaidOutRow] }`
    with `struct LaidOutRow: Equatable { var kind: RowKind; var frame: CGRect }`
  - `struct SoundMenuModel: Equatable` = Anode's own values (volume, muted, outputs, batteries) merged with the last
    `AppleSoundPanel` read, plus `var notice: String?` and `var expandedDevice: String?`; built by
    `static func merge(outputs: [OutputDevice], defaultID: String?, volume: Double, muted: Bool, batteries: [AccessoryBattery], apple: AppleSoundPanel?) -> SoundMenuModel`

- [ ] **Step 1: Failing tests:** `testMergeOrdersRowsLikeApple` (speakers, then AirPods, then AirPlay receivers from
  Apple's list, with Apple's order winning when present); `testAirPlayRowsOnlyFromApple`; `testFramesMatchMeasured`
  (for the fixture model: each row's frame equals the Task 1 table, panel height equals Apple's for the same state);
  `testCollapsedAirPodsHasNoListeningRows`.
- [ ] **Step 2: Run** `swift test --filter SoundMenuLayout` — Expected: FAIL.
- [ ] **Step 3: Implement.** Core Audio: `kAudioHardwarePropertyDevices`, output streams > 0, not hidden,
  `kAudioHardwarePropertyDefaultOutputDevice`, `kAudioHardwareServiceDeviceProperty_VirtualMainVolume`, mute; listeners on
  those three properties call `onChange` on the main queue.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Sound Menu: outputs, batteries, layout"`.

### Task 6: The menu panel and its controller

**Files:**
- Create: `Sources/AnodeApp/SoundMenuPanel.swift` (drawing, from `SoundMenuLayout` + `SoundMenuMetrics`),
  `Sources/AnodeApp/SoundMenuController.swift` (status item, open/close, actions)
- Test: `Tests/PowerKitTests/SoundMenuControllerTests.swift`

**Interfaces:**
- Consumes: Tasks 3–5.
- Produces: `final class SoundMenuController { init(settings: Settings, outputs: AudioOutputs, driver: SystemPanelDriving, batteries: @escaping () -> [AccessoryBattery], accessibility: @escaping () -> Bool, statusBar: StatusItemHosting); func start(); func stop(); var isMenuOpen: Bool { get } }`
  where `protocol StatusItemHosting` wraps `NSStatusBar.system` so tests use a fake.

- [ ] **Step 1: Failing tests (fakes for all four inputs):** `testStartsOnlyWhenEnabled`; `testOpenReadsAppleOnce`;
  `testPickingOutputSetsDefault` (Core Audio path, no driver call); `testListeningPressIsOptimisticThenConfirmed`
  (checkmark moves at once, driver `.done` tree keeps it); `testRefusalPutsCheckBackAndShowsLine` (driver `.refused("…
  both ears…")` → old checkmark, `model.notice` equals Apple's text); `testAdaptiveNotPressedWithOneBud`
  (batteries show only Right → no driver call, notice "Put both AirPods in to use Adaptive." — Apple's wording measured in
  Task 1); `testAirPlayRowPressesApple`; `testDeviceRemovedWhileOpenDropsRowAndSelection`;
  `testWithoutAccessibilityAppleRowsAreUnavailable` (rows present, disabled, notice names Accessibility, volume still
  settable); `testStopRemovesItemAndClosesMenu`.
- [ ] **Step 2: Run** `swift test --filter SoundMenuController` — Expected: FAIL.
- [ ] **Step 3: Implement.** The panel: borderless, non-activating `NSPanel` at the status item's position with the
  Task 1 material; closes on click outside (global and local monitors), Esc, a second click on the item. Hover
  highlights, disclosure triangle and slider behave as in the Task 1 captures. Status item: the `SoundIcon` symbol,
  updated on `onChange`.
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Sound Menu: the menu and its controller"`.

### Task 7: Wiring, quit and launch

**Files:**
- Modify: `Sources/AnodeApp/main.swift` (construct beside `menuBarHider`, ~line 447; start/stop on
  `soundMenuEnabled` changes; stop on quit)
- Test: `Tests/PowerKitTests/SoundMenuWiringTests.swift`

- [ ] **Step 1: Failing tests:** `testTogglingSettingStartsAndStops`; `testQuitClosesApplePanelIfOpen` (fake driver
  reports a panel in use → `stop()` waits for close, bounded by 1 s).
- [ ] **Step 2: Run** `swift test --filter SoundMenuWiring` — Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `swift test --filter SoundMenu` then `./test.sh --quick` — Expected: all PASS.
- [ ] **Step 5: Commit** `git commit -m "Sound Menu: wired into the app"`.

### Task 8: Hardware verification and pixel match (owner present)

- [ ] **Step 1: Install.** `pmset -g | grep SleepDisabled` reads 0; `./build-app.sh`; `BSSourceCommit` equals
  `git rev-parse --short HEAD`; running inode matches. Turn the setting on.
- [ ] **Step 2: Pixel match.** For every state captured in Task 1, capture Anode's panel the same way and overlay it on
  Apple's (difference image, same background). Fix and repeat until the only differences are from what lies behind the
  glass. Record the final differences under "Measured".
- [ ] **Step 3: Every row works:** volume; each output; each listening mode (both AirPods in); Adaptive with one bud
  (not pressed, the line shows); Conversation Awareness; an AirPlay receiver (owner's choice which, then back);
  both Settings buttons.
- [ ] **Step 4: Never on screen:** 20 uses by the owner's eye, and a 120 fps recording of the top-right corner during 10
  of them (`ScreenCaptureKit` probe, window-free region capture only with the owner's OK). No Apple panel, alert or
  pressed icon visible.
- [ ] **Step 5: Without Apple's icon** (only if the owner agrees to remove it for the test, and put back after): every
  row still works through Control Center; record timing.
- [ ] **Step 6: Quit, `kill -9`, relaunch** while the menu is open and while a press is in flight: no Apple window left;
  menu comes back. Record results under "Measured" and commit.

## Measured

### Task 1 (2026-11-15, owner present; probes in the session scratchpad `sound/`)

- **Apple's panel geometry (macOS 27, 14" MacBook Pro, dark):** the window is 522x1102 pt and mostly transparent; the
  visible panel is 309x537.5 pt at (window x + 181.5, window y + 2), opaque bbox 618x1075 px at 2x. Body colours (dark):
  base #202020, the expanded AirPods section #343434. Row frames (pt, screen): volume slider (1302,78) 230x16, lower
  button (1284,79) 9x13, higher (1538,78) 21x15; "Output" heading (1282,114); device rows 298x32 at x 1273 (y 132,
  164, 455, 487); listening rows 298x26 at y 233/257/281; Spatial heading y 321, row y 338; Conversation heading
  y 378, rows y 395/419; Settings buttons (1273,518) 257x16 and (1273,540) 121x16.
  Full tables to be refined against overlays in Tasks 5 and 8.
- **Q1 (our menu open while Apple's panel opens off screen): PASS.** A probe `NSPanel` stayed visible; no focus change
  (frontmost app unchanged, our app not active, Control Center not active).
- **Q2 (Apple's icon while its panel is open off screen): FAIL as the plan defines no-go.** The icon shows its pressed
  pill for as long as the panel is open (3120 of 4488 px differ from the idle capture, max delta 39). Pressing a row
  and closing at once keeps it to about 110 ms; a read needs the panel open about 200-300 ms.
- **A press still lands when the panel is closed at once** (the refusal alert for Adaptive with the buds in the case
  appeared after an immediate close), so a press needs about 110 ms of panel time; only the read-back needs a longer
  one. Read-back can wait for the next time the menu opens.
- **Q7 (refusal alert): the window-created observer moved the alert to x = -4000, but it came back to x = -220,
  leaving about 40 pt of it on screen at the left edge** until OK was pressed. Mitigation to build: dismiss the alert
  the instant it is created, and avoid presses Apple is known to refuse.
- **Owner's decision on Q2: cover Apple's icon briefly with a still picture of its idle look** (asked 2026-11-15).
  **Measured: it works.** A borderless clear window at `CGShieldingWindowLevel() - 1`, placed on whole pixels over the
  icon's rect (x = Int(minX) - 6, width = Int(width) + 12, height 33), showing a capture of the idle icon: with Apple's
  panel open off screen the covered region differs from the idle capture by **0 of 4488 px**; without the cover, 3120.
  The icon's pressed look fades for about 1 s after the panel closes (a capture 1.0 s after close still differed, 954
  px, delta 18), so keep the cover up about 1.2 s after every close. Take the idle capture before the first use of a
  session, and again whenever the output device or volume changes the icon.
- **Ruling (executor):** the rest of Task 1's measuring (layout table, material, light appearance, other states, Q3-Q6)
  is done inside the tasks that need each number (metrics in Task 5, material in Task 6, states and light/dark in
  Task 8's overlay loop). The go/no-go question it existed to answer is settled. Cost if wrong: a few numbers are
  measured later than planned.
