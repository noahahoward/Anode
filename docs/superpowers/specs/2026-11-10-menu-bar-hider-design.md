# Menu Bar Hider: design

Supersedes `docs/superpowers/plans/2026-11-05-menu-bar-hider.md`, whose method (a very wide status item that pushes icons off the bar) was measured as no-go on this Mac on 2026-11-06.

## Intent

The owner's menu bar gets close to the notch. macOS copes by silently parking the icons that do not fit at the far left edge, off the bar, where they cannot be seen or clicked. On the owner's 14" notched MacBook that is currently six icons: G HUB, 1Password, OpenVPN (two items), WireGuard, Synology Drive.

The owner uses every one of these icons, and could happily keep all of them out of sight, except battery, sound and Wi-Fi, until asking for them. So: a **chevron** in the bar; the bar otherwise shows only battery, sound and Wi-Fi; pressing the chevron (and only that, never hover) opens a **pill**, a floating panel centred under the notch, holding every other icon, each one clickable as if it were the real icon. Which icons are always on the bar and which sit behind the chevron is **arranged by drag and drop**.

The owner's words for the trigger: "when it starts getting too close for comfort to the notch."

## States (what each control acts on)

*(author's calls, settled after the builder check; the owner said "all could live out of sight … until I press expand", so the bar is collapsed for as long as the feature is on, not only when crowded.)*

- **Collapsed** is the resting state while the feature is on: the cover is up, Anode's hidden widgets are off the bar, only the always-visible icons and the chevron show. There is no automatic crowding trigger; the existing widget density squeeze (`MenuBarWidgetController.Density`) is simply not used for widgets that are folded away.
- **The pill is open or closed**; the bar stays collapsed either way. The chevron click, the shortcut (⌃⌥⌘B) and the right-click "Show icons / Hide icons" all toggle the **pill**. "Hide again after" closes the pill. Nothing in normal use uncovers the real bar.
- **Uncovered** exists only as "Turn off": the setting off, quitting, or a refusal (permission missing, layout unreadable, full-screen). Turning the feature off removes the cover and restores Anode's widgets.

## Goals

- Collapsed bar: only the always-visible icons (default battery, sound, Wi-Fi) plus the chevron. The clock and Control Center stay too *(author's call: they are part of the system's right-hand cluster and hiding them is not what was asked for)*.
- Every hidden icon, including the six macOS has already parked, is reachable from the pill.
- Drag-and-drop arrangement in the Beta Features section: two groups, "Always on the bar" and "Behind the chevron", plus order inside the pill.
- Pressing an icon in the pill opens that icon's own menu.
- Off by default (Beta Features). With it off nothing exists: no cover, no observers, no timers. Quitting or crashing Anode puts the bar back exactly as macOS had it.

## Non-goals and anti-goals

- No hover-to-reveal. No auto-hiding of the real menu bar. No FPS-style extras.
- Not a rewrite of what the icons do: the pill shows and forwards, it never replaces an app's own menu.
- Anti-goal: an icon the owner cannot reach by any route (as today's parked six). The feature has failed if a hidden icon cannot be opened from the pill.
- Anti-goal: covering something the owner did not choose to hide, or leaving a cover on screen when the layout it was computed for has changed.
- Anti-goal: freezing Anode. Accessibility calls to other apps have frozen Anode before (see memory `anode-freeze-root-cause`); every call to another app's accessibility tree has a short timeout and none runs on the main thread's critical path.

## What was measured (spike, 2026-11-10, read-only, no cursor and no window switching)

Probes: `docs/superpowers/spikes/2026-11-10-menu-bar-hider-ax-probe.swift`, `…-cover-probe.swift`; screenshots `…-before.png`, `…-covered.png`.

- **Status items are not windows** on macOS 27: neither `CGWindowListCopyWindowInfo` nor ScreenCaptureKit lists them (not even Anode's own). They cannot be captured one by one by window id. `CGWindowListCreateImage` is unavailable in this SDK.
- **The Accessibility extras menu bar lists every item** (`AXExtrasMenuBar` of each running app; 19 items measured) with position, size and an `AXPress` action. Needs Accessibility, which Anode already asks for. Reading is passive.
- **Layout measured:** screen 1800×1169 pt, notch 790…1010 (220 pt wide). Right of the notch: Anode's own eight items (x 1114–1500) and the system's items (x 1507–1780). The six third-party items are parked at x −1 to 7, y 1157: off the bar.
- **A cover works.** A borderless non-activating panel at `.screenSaver` level, black, over x 1108–1504 removed Anode's widgets and their neighbours from the picture entirely, leaving Wi-Fi, sound, battery, Control Center and the clock. The owner's bar is solid black, so the cover is seamless there.
- **Not measured yet** (needs the owner at the Mac): that `AXPress` opens an item's menu and where the menu lands, especially for a parked item; and that the parked six return to the bar when Anode's own items stop taking room.

## Approach

1. **Read the bar.** An `AXExtrasMenuBar` reader lists every item (app, position, size, press action) on a background queue with a short messaging timeout, republished when the layout changes.
2. **Make room.** While collapsed Anode removes the *own* menu bar widgets and icons the owner put behind the chevron from the bar and shows them in the pill like every other icon. Each Anode widget is arranged individually: one dragged into "Always on the bar" stays a real status item. *(author's call)* The removed ones must be **destroyed, not hidden** (`isVisible = false` is saved per `autosaveName` and would survive a crash with the widget missing). In the pill, Anode's widgets are drawn by Anode with live readings and open their existing group menu anchored to the pill; they are not captured or pressed like other apps' items. The ~400 pt this frees should let macOS lay the parked six out again (to be confirmed on the owner's Mac; if it does not, say so in the section rather than look broken).
3. **Cover.** Solid panels (the bar's own colour: for a plain black bar, black; otherwise sampled from the bar next to it) over each run of items that are not always-visible: macOS decides the order on the bar and Anode cannot move other apps' icons, so an always-visible icon sitting between hidden ones is left showing in a gap between two covers *(author's call)*. Recomputed from step 1 whenever the layout changes. It swallows clicks, so a click on the cover cannot reach an icon underneath.
4. **The pill.** A non-activating panel centred under the notch, showing each hidden item as a picture. Pictures come from a ScreenCaptureKit capture of the bar region (excluding Anode's own windows) cropped by each item's accessibility frame; an item that cannot be captured (parked, off the bar) shows its app's icon. Wraps to more rows when needed.
5. **Forwarding.** Pressing a picture performs `AXPress` on that item. The menu opens where the real item is; for a parked item the placement is to be measured, and the section says honestly if it cannot be made good.
6. **The chevron** is one Anode status item (always visible) and a toggle shortcut *(author's call: ⌃⌥⌘B)*. Right-click opens a menu: Hide/Show icons, "Hide again after" 5 s / 10 s / 30 s / Never, Open Beta Features…. The pill closes when the owner clicks away, presses the chevron again, or after the chosen time *(author's call: default 10 s)*.
7. **Arranging.** The Beta Features section shows the two groups and the order inside the pill, all as drag and drop, built from the items found in step 1 (pictures as in step 4). The choice is stored by each item's app and position-independent identity so it survives relaunches *(builder: choose the identity; an app with several items, like OpenVPN, must be handled)*.

## Scope of screens

v1 acts on the screen that carries the status items (the built-in notched screen on the owner's Mac). The pill sits centred at the top of that screen, under the notch if there is one *(author's call)*. Other displays' bars, the lid-closed external-display case and "Displays have separate Spaces" are out of scope: when the status items are not on that screen the feature stands down (no cover, chevron stays) and the section says why.

## Constraints

- macOS 13 deployment target; no new dependencies; Beta Features section "Menu Bar Hider", setting `menuBarHiderEnabled`, default false.
- Needs Accessibility (reading and pressing) and Screen Recording (pictures); each missing permission is stated in the section with a button to open its pane, and the feature degrades (no pictures → app icons; no Accessibility → the feature refuses to collapse).
- Never cover anything during full-screen apps or within ~1 s of a Space or display change, and never leave a cover up when the layout under it has changed: a stale cover is worse than none.
- Anode's own always-visible choices (the chevron itself) can never be moved behind the chevron.
- Idle cost near zero: no polling faster than needed; the layout is re-read on events (screen, Space, app launch/quit, Anode's own widget changes), with a slow fallback.
- Tests never create a real cover, status item or accessibility call; the real thing runs only in hardware steps, when the owner is at the Mac, because it changes the bar.

## Left to the builder

The exact event set that triggers a re-read; item identity for persistence; the drag-and-drop mechanics in AppKit; how the pill chooses its row layout; the bar-colour sampling for non-black bars; whether `AXObserver` notifications are reliable enough to replace the fallback timer.

## Open risks (each gets a measured step in the plan before anything depends on it)

1. The parked six may not return when Anode's items leave the bar (macOS decides).
2. `AXPress` on a parked item may open its menu in the wrong place.
3. The bar's colour may not be a flat colour on other setups (translucent bar over a wallpaper): the cover would then show as a patch.
