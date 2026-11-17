# Battery menu, exact copy: plan

Spec: `docs/superpowers/specs/2026-11-15-sound-and-battery-menus-design.md` (step 3: Apple's rows only; the additions are step 4).
Owner order, 2026-11-17: Sound menu shipped as 1.22.0; the Battery menu is next, on branch `battery-menu`.

## Measured on macOS's own Battery panel (macOS 27, 14" MacBook Pro, dark), 2026-11-17

Panel 308 pt wide (x 1306 to 1614 here), 277.5 tall, top at y 41 (below the 39 pt bar; the Sound panel is 309 wide, top 41). Rows are 280 wide, set in 14 from each side (Sound's are 298 wide, set in 5). All y below are from the panel's top.

| What | y | h | Notes |
|---|---|---|---|
| "Battery" title | 12 | 16 | AX static text, id `battery-header` |
| "Power Source: Battery" | 37.5 | 15 | secondary colour; also id `battery-header`; says "Power Adapter" on the charger |
| divider 1 | 59.5 | 1 | |
| "Energy Mode" heading | 68.5 | 15 | AXHeading |
| Automatic / Low Power / High Power | 87, 119, 151 | 32 each | AXCheckBox ids `energy-mode-automatic`, `-low`, `-high`; value 1 = selected; round badge with a battery glyph, selected one blue |
| divider 2 | 188.5 | 1 | |
| "Using Significant Energy" heading | 197.5 | 15 | only while some app is using significant energy |
| each such app | 216 | 22 | AXButton, desc = app name; icon + name |
| divider 3 | 243.5 | 1 | |
| "Battery Settings…" | 249 | 22 | AXButton |

Still to measure: glyphs and their sizes, fonts and colours (likely those of the Sound panel), the hover highlight, what a row looks like pressed, the heading when more than one app is listed, the panel with no significant-energy apps (divider 2 and the heading go), the charger state (Power Adapter, Low/High availability, "Charging" line?), battery percentage, and every animation (a row appearing, the mode changing).

## Reuse from the Sound menu

`SystemPanelKind.battery` and the press driver already exist (they read `energy-mode-*`). Reuse: the glass material, `HoverRow`, `BadgeView`, the glide between layouts, `CoverPresence`/`IconCover`, `NativeIconClickGate`, and the measuring tools (recorder, bands, lens profile) in the session scratchpad.

## Tasks

1. **Metrics, model, layout** (PowerKit, pure): `BatteryMenuMetrics`, `BatteryMenuModel` (Apple's reading: power source line, energy modes with selected, significant-energy apps), `BatteryMenuLayout.frames(for:)`; tests pin the numbers above, with and without the significant-energy section.
2. **Reading**: `AppleBatteryPanel` parsed from the Control Center tree (AX ids above), with tests from recorded trees.
3. **Controller**: opens from a click on macOS's Battery icon (the icon gate made generic over the item id), reads Apple's panel off-screen first, presses `energy-mode-*` through the driver, optimistic selection, the same open/close rules as Sound.
4. **Panel view**: draws the rows from the layout (glass, fonts, glyphs, hover, glide as rows come and go).
5. **Setting**: a Beta Features switch "Battery menu" (off by default; the Sound menu's pattern).
6. **Verification against Apple**: overlay over flat backdrops, hover, press, animation, light appearance; then the additions of step 4.

## Progress
- 2026-11-17 Task 1 done (`BatteryMenuMetrics/Model/Layout`, 6 tests). Task 2 done (`AppleBatteryPanel.parse`, 7 tests; a tree that is not the panel gives nothing). Next: task 3, with the icon gate generalised over the item id (`NativeSoundIcon` is tied to `com.apple.menuextra.sound`).
- 2026-11-17 Task 3 done: `NativeSoundIcon` is now `NativeMenuExtraIcon(identifier:logName:)` (`.sound()`, `.battery()`; one tap box per identifier; checked live: the Battery item is a one-child group like Sound's, 26 pt wide). `BatteryMenuController` (read `.battery` off-screen, press `energy-mode-*`, optimistic check, last reading kept in `batteryMenuLastReading`, opens at once with it or on the first reading when nothing is known, no accessibility means no opening) with `BatteryMenuPresenting`; settings `batteryMenuEnabled` (off) added; 18 tests. Not wired into `main.swift` yet: it needs the drawn menu (task 4). Open: whether macOS's panel stays open after an Energy Mode is chosen (assumed yes), refusal notice (none).
- 2026-11-17 Tasks 4 and 5 done, task 6 mostly: `BatteryMenuPanel.swift` (panel, content view, `ModeRow`/`EnergyAppRow`/`FooterRow`, `BatteryGlyphs`), `BatteryMenuFeature` ("Battery Menu" in Beta Features, off by default), wired in `main.swift` with one `SystemPanelDriver` shared with the Sound menu. Checked on screen against macOS's own panel (dark): text, glyph, badge and divider boxes identical to the pixel; hover highlight 7 pt in from each panel edge, 10 pt corners, +19 levels on every row (mode, app, footer); a pressed row dims its content to 0.8 and loses its light when the pointer leaves; the panel stays open after a mode is chosen; two apps listed: rows 22 pt apart, footer 22 pt lower; choosing Low Power / High Power in Anode's menu changed `pmset powermode` 2 -> 1 -> 2. Panel top: window 40 pt down, picture 0.5 pt under the window's top (AppKit rounds a half-point window outward, and the picture jumped half a point between openings until it was pinned). High Power's glyph is drawn (SF Symbol `arrowtriangle.right.3.battery.0percent` exists in Control Center's binary but does not resolve).
  Open: light-appearance glass is ~17 levels darker than macOS's on the real wallpaper (same for the Sound menu; flat-backdrop numbers earlier said 0.10 lift); dark glass not compared on a stable backdrop; the opening flash of macOS's own panel not frame-checked for Battery (driver is shared with Sound); what pressing an app row does; charger state; animation when an app row appears or goes (the panel resizes at once); no refusal notice.

