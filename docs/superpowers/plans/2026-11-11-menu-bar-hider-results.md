# Menu Bar Hider: results

Measured on the owner's 14" notched MacBook, macOS 27, screen 1800×1169. Probes: `docs/superpowers/spikes/2026-11-11-menu-bar-hider-ids-probe.swift`, `…-flatness-probe.swift` (the latter hung waiting for a Screen Recording prompt and was replaced by `screencapture -R`, see step 4). Everything below was read-only: no cursor movement, no window switching, nothing pressed.

## Task 9, step 1: what the bar looks like to Accessibility (read-only)

- 18 items. Four are parked at x −1…7, y 1157 (G HUB, 1Password, WireGuard, Synology Drive; OpenVPN was not running). Anode's own items: x 1067–1495 (eight widgets at the time).
- **The system's items all belong to `com.apple.MenuBarAgent`**, not Control Center. Each is an `AXHostingView` group with no actions of its own; the **first child** (`AXMenuExtra`) carries `AXIdentifier`: `com.apple.menuextra.focusmode`, `.wifi`, `.sound`, `.battery`, `.controlcenter`, `.clock`. Their `AXAttributedDescription` is the name ("Wi‑Fi, connected, 3 bars", "Sound", "Battery", "Control Center", "Clock").
- **Third-party items carry no identifier, no title and no description.** G HUB, 1Password, WireGuard and Synology Drive have an empty title and no description; they are told apart only by their order among their app's items (`bundle|#0`). They do have `AXPress`, and their first child is their `AXMenu` (reading it is passive).
- Anode's own items carry their name in the description ("Memory used", "CPU usage", …).
- Departure from the plan: the reader reads the identifier and description from the first child when the item is a hosting group, and presses the child when the group has no `AXPress`. The item key for the system's items is `com.apple.MenuBarAgent|com.apple.menuextra.<name>`, which the default arrangement (battery, sound, wifi) and the locked list (clock, controlcenter) already match.

## Task 9, step 4 (risk 3): is the bar a flat colour? (read-only)

Four captures of the top 8 pt of the bar over x 1060–1500, 20 s apart, with `screencapture -x -R1060,0,440,8`: every pixel black (luminance 0…0, brightest channel 0) in all four. The bar on this Mac is solid black, so a black cover is seamless. A non-black or translucent bar was **not** seen; the cover is black regardless and the Beta Features section will say a coloured bar may show a patch. (Colour sampling for such a bar was left out: nothing here can test it.)

## Not yet measured (need the owner's go-ahead)

- Risk 1: do the parked items return when Anode's widgets leave the bar? (step 2)
- Risk 2: where does `AXPress` open an item's menu, for an on-bar item and a parked one? (step 3)

## Task 15, hardware pass (2026-11-11, owner at the Mac; no cursor, no clicks, no window switching)

Probes: `docs/superpowers/spikes/2026-11-11-menu-bar-hider-press-probe.swift` (AXPress, menu frame, screenshot, AXCancel).

**Measured, working**
- Turning the setting on and relaunching: the bar read `Anode widgets (8) → gone`, the chevron appeared at x 1425, Keep Awake (Anode's own item, not a widget) stayed, and the system's Wi-Fi, sound, battery, Control Center and clock stayed. Log: `collapsed: 0 cover(s), 11 behind the chevron` (four parked icons and seven Anode widgets).
- The pill (opened with an accessibility press of the chevron): a dark pill centred under the notch holding the app icons of G HUB, WireGuard, Synology Drive and 1Password and Anode's own widgets drawn live (Drain, Left, CPU, RAM, GPU, Swap, the group glyph). It closed by itself after 10 s.
- Turning the setting off and relaunching: Anode's eight widgets were back at x 1097–1459 and the chevron was gone. Relaunching with it on three times left the bar whole each time, so quit-while-collapsed is safe.
- **Risk 2, on-bar item:** `AXPress` on the Wi-Fi item opens its normal panel directly under the icon.

**Measured, not what was hoped**
- **Risk 1: the four parked icons did NOT come back** when Anode's widgets left the bar, with about 380 pt free. macOS keeps an item parked until its app relaunches (not tried: it would mean quitting the owner's apps). They are reachable only through the pill.
- **Risk 2, parked item:** `AXPress` on WireGuard's parked item returns `kAXErrorCannotComplete` (−25204) after about 1.7 s but the menu does open, at the **top-left corner of the screen** (frame −5, 1, 199×187) over the Apple menu, not under the pill. It is readable and clickable and closes with `AXCancel`.
- `AXCancel` does not close the system's Wi-Fi panel; a second `AXPress` on the item does.

**Mistake, corrected:** the first press probe took Anode's first status item, which was Keep Awake, and started a Never Sleep session. Quitting Anode released it (`pmset` showed no Anode assertion afterwards; Keep Awake log: `state: off`).

**Not verified**
- The ⌃⌥⌘B shortcut (needs a real key press), a click on the chevron or a pill cell, and a drag in Beta Features (need the pointer). Pressing an item in the pill with a real click.
- Where a pill-forwarded press on a parked item lands is known (top-left), so its menu will not be under the pill.

## Second hardware pass (2026-11-11, build 1.16.0; display awake, still no cursor or clicks)

- **Cover over a real item: works.** Test arrangement with Sound behind the chevron (Wi-Fi and battery pinned), feature on, relaunch.
  Log: `collapsed: 1 cover(s), 12 behind the chevron`. The screenshot shows chevron, Keep Awake, Wi-Fi, a seamless black gap
  where Sound was, battery, Control Center, clock.
- **Pill (chevron pressed with AXPress):** Sound first, then the four parked apps' icons, then Anode's widgets live, wrapped to a
  second row for the eighth. Closed itself after 10 s.
- **Found and fixed:** Sound's captured picture sat on a tan patch. The capture left out every Anode window, including the menu bar
  backdrop that paints this bar black, so it photographed the wallpaper. Now only the hider's covers and pill (tagged
  `dev.anode.menuBarHider`) are left out; the re-test shows the picture on black.
- Settings put back afterwards (arrangement key deleted, feature off); the bar came back whole.

## After the second review (2026-11-11, build 5f99dd8)

A fresh whole-branch review found ten problems (stale covers on layout shifts with no event, a parked chevron, a timeout
read as "no items", exact-width comparison of reads, a 30 s scan of every app, force casts, random order, a press reaching
the wrong sibling, an empty pill, build-app.sh ending silently). All fixed with tests; suite 2290 tests, 0 failures.

- **Found on hardware and fixed:** with "any timeout fails the read", `universalaccessd` (no menu bar items) answered
  `AXError -25204` on every read and the hider never collapsed (`stand down: layoutUnreadable`). Now an app's silence fails
  the read only for the system's owners, Anode, and apps seen with items before.
- **Re-test:** collapsed with 2 covers: Sound (test arrangement) and AlDente, started since the last pass, which appeared on
  the bar at x 1393 and went behind the chevron by default. Both covers seamless; the chevron was recognised by its label.
  The pill showed Sound and AlDente as captured pictures on black. Settings put back; the bar came back whole, AlDente included.
- **macOS 27.0 has no overflow arrow here** (read-only probe: no `AXOverflowButton`, no arrow child or hit), so a parked
  icon's menu keeps opening at the top-left; the Beta Features section now says so.
- **Unmeasured risk (from Thaw's source):** AXPress on a parked item may leave MenuBarAgent keeping the bar shown in
  full-screen apps until it restarts. Owner to check once.
