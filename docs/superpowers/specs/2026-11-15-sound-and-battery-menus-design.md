# Sound and Battery menus: design

Date: 2026-11-15. Owner's request, worked out in conversation the same day. Decisions the owner made are stated plainly;
anything marked *(builder's call)* or *(author's call)* was not decided by the owner.

## What this is, and why

Anode puts two menu bar items next to macOS's own Sound and Battery items. Each one opens a menu that is an **exact
copy of the macOS menu, down to the pixel**. Once each copy is exact, Anode adds its own controls:

- **Sound:** per-app volume. Every app connected to the sound system gets a mute button and a 0–100% slider.
- **Battery:** a shortcut to Anode's Beta Features settings, a charge limit slider with a Soft Drain button (hold it
  for Hard Drain), and Ultra Low Power Mode as a fourth Energy Mode.

The reason: the owner wants one place for sound and one place for power, the place they already click, with Anode's
features in it. Per-app volume needs a home, and the Sound menu is that home. Charge Control and Ultra Low Power Mode
belong where the battery already lives.

## Order of work (owner's)

The copy comes first, and nothing of Anode's goes into a menu until that menu matches macOS.

1. **Sound menu, exact copy.** Apple's rows only.
2. **Per-app volume** added to it.
3. **Battery menu, exact copy.** Apple's rows only.
4. **Battery additions:** settings shortcut, charge limit and Soft/Hard Drain, Ultra Low Power.

*(Author's reading: the owner first listed this order, and later said "start by reconstructing the menus pixel per
pixel, then add our functions". Either way each menu is exact before anything is added to it. If the owner meant both
copies before any addition, swap 2 and 3; nothing else changes.)*

## Goals

- **Exact copy.** The menu bar icon and the menu look and behave like macOS's own on this Mac (macOS 27, MacBook Pro
  14"):
  - the same size, glass, corner radius, fonts, weights, colours, spacing, icons, checkmarks, dividers, row heights,
    hover highlights, disclosure triangles and order;
  - the same opening and closing behaviour (click, click outside, Esc).

  "Exact" is checked by measurement: put screenshots of both menus over the same background, overlay them, and
  compare them pixel by pixel. Judging by eye doesn't count.
- **Everything in the copy works.** Every row does what Apple's row does, including the parts Apple keeps to itself:
  - AirPods listening mode, Spatial Audio and Conversation Awareness;
  - AirPlay speakers;
  - the "Using Significant Energy" list.
- **Removing Apple's icon is the user's choice.** Anode works whether Apple's icon is in the bar or not, and never
  removes or hides it by itself. While we test, both icons are in the bar.
- **Per-app volume (step 2):**
  - **Which apps:** the apps that are open and connected to the sound system. In practice that means every app with
    an audio process object in Core Audio, grouped to the app it belongs to. This includes apps that are silent at the
    moment. Apps that never opened sound don't appear. *(Owner, 2026-11-16: every open app that has this permission is
    listed at 100% and unmuted even while it plays nothing. Silent is not muted: only a muted app is muted.)*
  - **Each row:** the app's icon and name, a mute/unmute button, and a slider from 0 to 100%, defaulting to 100%. The
    old plan's 0–200% is replaced by the owner's 0–100%.
  - **Where:** a section headed "Apps", in the same heading style as "Output", directly under the main volume slider
    and above Output.
  - **Remembered:** each app's volume and mute stay through quitting the app and restarting the Mac, keyed by bundle id.
- **Battery additions (step 4):**
  - **A small settings (gear) icon in a corner** opens Anode's Beta Features window. *(Author's guess: top right, level
    with "Battery".)*
  - **A charge limit slider with a minus button beside it.**
    - The slider sets the charge limit (Charge Control's range, 20–100%).
    - A press of minus starts or stops Soft Drain to Limit, the same as `ChargeController.pressDrain()`.
    - Holding minus for **3 seconds** brings up a box on screen asking "Would you like to Hard Drain?". Yes runs
      `ChargeController.pressHardDrain()`.
  - **Ultra Low Power as a fourth Energy Mode**, below High Power, in exactly the same row style (round icon, label).
    - Choosing it shows the existing confirm box, then starts the mode.
    - *(Author's guess:)* choosing Automatic, Low Power or High Power while it is on turns it off. That still counts as
      turning it off by hand, so the owner's "only manual on, only manual off" rule holds.
- **Each addition shows only while its own Beta feature is on (owner):**
  - the charge limit row only while Charge Control is on;
  - the Ultra Low Power row only while Ultra Low Power Mode is enabled;
  - the Apps section only while per-app volume is on.

## Non-goals

- EQ or tone controls (owner, 2026-11-06).
- Removing, hiding or moving Apple's icons. The Menu Bar Hider keeps system icons locked (owner's earlier rule).
- Per-app control of Safari and other WebKit apps in v1: their sound plays through a system process, `WebKit.GPU`
  (spike, 2026-11-06).
- Any copied code, name, artwork or wording from other products. Apple's own menus are the model.

## Anti-goals: these count as failure even if the rest works

- Apple's panel or one of its alerts appearing on screen, even briefly, when the person used Anode's menu.
- An app left silent because Anode took its sound and then delivered nothing (the permission trap, below).
- A system setting changed without the person asking, or not put back.
- A copy that is close but noticeably different. The owner's words: "EXACT REPLACEMENT FIRST. DOWN TO THE PIXELS".

## How it works, as far as the owner decided and the probes proved

### What Anode can do itself (public macOS calls)

| Row | How |
|---|---|
| Volume slider | Core Audio virtual main volume on the default output |
| Output list: Mac speakers, AirPods | Core Audio devices and the default output device |
| AirPods battery, per bud and the case, with charging | `IOPSCopyPowerSourcesByType(0)` (IOKit, looked up at run time; no permission). These are Accessory Source entries with Part Identifier Left, Right or Case. |
| Battery level, Power Source line | Anode already reads these |
| Energy Mode: Automatic, Low, High | `PowerModeSwitch` through the Anode helper (already shipped) *(author's call: use the helper, and fall back to Apple's panel below when the helper is missing)* |
| "…Settings…" buttons | open the matching System Settings pane |

### What only Apple's own panel can do

Apple keeps these controls to its own apps. The private calls exist, but they answer only an app that holds an
entitlement Apple grants to itself. Without it they return nothing, and a copy that claims the entitlement anyway is
killed by macOS at launch (probe, 2026-11-15). These rows are:

- listening mode (Transparency, Adaptive, Noise Cancellation);
- Spatial Audio;
- Conversation Awareness;
- AirPlay speakers (the Denon and the Roku here);
- "Using Significant Energy".

They are read and pressed **through Apple's own panel, by Accessibility, with the panel moved off the screen**.
Measured on this Mac:

- **Where the items are.** Apple's menu bar items belong to `com.apple.MenuBarAgent` (Accessibility attribute
  `AXExtrasMenuBar`). Their ids are `com.apple.menuextra.sound`, `.battery`, `.controlcenter` and `.clock`.
- **Opening.** Pressing the Sound item opens the panel as a `com.apple.controlcenter` window (subrole
  `AXSystemDialog`) in 60–110 ms.
  - Every row is an Accessibility checkbox or button with a stable id, for example
    `controlcenter-volume-slider`, `sound-device-<name>` and `energy-mode-low`.
  - Each row carries its current on/off value.
  - Reading the whole panel takes about 150 ms.
- **Moving it off the screen.** The window's position can be set.
  - An Accessibility observer on "window created" moves it off the screen within the same millisecond it appears.
  - The window server still listed it on screen for up to 14 ms after the move.
  - The owner saw no flash in 10 runs.
  - Apple may reuse the window, in which case no "created" notice comes, so set the position again once the window is
    found.
- **Pressing.** Pressing a row works while the panel is off the screen. Transparency → Adaptive → Transparency all
  switched the owner's AirPods.
  - Read the result **about 1 s or more after a press**. 0.4 s read stale.
  - Press Apple's item again to close the panel, and make sure no window is left behind.
- **Refusals.** When Apple refuses a change, it opens a separate alert window beside the panel, partly on screen.
  - The alert reads "Failed to set listening mode / Put … in both ears to use Adaptive Audio." and has an OK button
    with id `action-button-1`.
  - Anode must catch it immediately, read its text, press OK, put its own checkmark back, and show Apple's reason as
    one line in Anode's menu.
- **When Apple's Sound icon is removed.** Pressing the Control Center item opens Control Center. Its "Sound" button
  (id `controlcenter-volume`) leads to the same rows. Its Battery button (id `controlcenter-battery`) does the same for
  the Battery rows. The Control Center item is always in the bar, so this route always exists. It takes one more step
  and is slower.
- **Permission.** All of this needs Accessibility. Anode already has it on this Mac. Without it, the rows that depend
  on it show as unavailable, with a line saying why.

### Per-app volume

Per-app volume follows `docs/superpowers/plans/2026-11-05-per-app-audio.md` and its measured spike, with these changes:

- the range is 0–100%;
- the controls live in the Sound menu's Apps section instead of a Beta Features list;
- which apps show up follows the rule above.

Everything else in that plan still holds:

- a private Core Audio process tap per changed app, and **no tap at all for an app left at 100% and unmuted**;
- ramped gain;
- following output device changes;
- the permission rule. "System Audio Recording" granted with every call succeeding returns silence, so Anode leaves
  an app's sound untouched until a preflight says the permission is granted.

## Constraints

- macOS 27 on the owner's MacBook Pro first. The package target stays where it is: gate newer calls with
  `#available` and leave the feature off where they are missing.
- Both menus are Beta Features, off by default *(author's call)*. Per-app volume is its own Beta feature (owner: the
  Apps section shows only while it is enabled).
- No other product's name in code, UI, tests, commits or docs. Call the owner's charge features by their Anode names:
  Charge Control, Soft Drain to Limit, Hard Drain, Ultra Low Power Mode.
- Release rules in `CLAUDE.md`: version bump, CHANGELOG, UPDATE-NOTE and annotated tag on every push. Push only on the
  owner's word.
- Tests never touch the real settings, the real menu bar, Apple's panel, real audio or real power state. Anything that
  does is a hardware check, done with the owner present.
- Apple's panel is opened only when Anode needs it. It is always closed afterwards, and nothing of it may stay on the
  screen.

## Owner's idea: open from macOS's own icon (2026-11-15, built)

Instead of a second icon, a click on macOS's own Sound icon opens Anode's menu. The bar keeps just macOS's icon, exactly as it is.

- **Option, off by default:** "Open it from macOS's own Sound icon instead (one icon, not two)", greyed out while the Sound menu is off.
- **How:** an active event tap on the shared tap thread swallows the press and release that land on the icon. A press is taken
  only inside the icon's last known frame, only when a fresh Accessibility look at what is under the pointer says it is the
  Sound icon (measured under 1 ms), and not with Command, Option or Control held (Command-drag rearranges icons). The release
  of a press taken is taken too. Anything that fails is passed on untouched.
- **If macOS's icon is removed** (System Settings), Anode's own icon appears by itself within a second, and goes again when
  macOS's returns. Removing it stays the person's choice.
- **Measured:** a click on the icon opened Anode's menu at macOS's own spot and macOS's panel did not open; a second click closed
  it; a Command-click passed through.
- **The panel's own pressed look:** because the click never reaches macOS's icon, it does not light up for a click at all.

## Open questions the builder must measure before building on them

1. Does opening Apple's panel, even off the screen, close Anode's own menu while that menu is open? If it does, Anode
   needs to read Apple's state before its menu opens, or keep its menu up some other way.
2. Does Apple's menu bar icon show its pressed highlight while its panel is open off the screen? If it does, that
   flash is on screen.
3. When should Anode read Apple's state? Options: every time Anode's menu opens (about 150 ms), or kept up to date in
   the background. Background reading must cost nothing measurable on battery.
4. How long does the Control Center route take compared with the direct route?
5. While Anode is driving Apple's panel, what happens if the person opens Apple's own Sound menu (when its icon is
   present)?

6. Does the off-screen panel take keyboard focus or activate Control Center? Does it disturb typing in the front app,
   or behave differently on another Space or over a full-screen app?
7. Is the Control Center refusal alert also caught by the "window created" observer, so it can be moved off the screen
   before it draws? In the probe it landed partly on screen at x = -220.

## Calls made from the builder check (author's, the owner can overrule)

- **"Never on screen" is measured two ways:** by the owner's eye over a pass of runs, and by a 120 fps screen
  recording of the menu bar corner during the hardware check. Every new `com.apple.controlcenter` window, including
  alerts, is moved off the screen as soon as it is created, not only the panel. Where Anode can know in advance that
  Apple will refuse a change, it does not press it. One example is Adaptive with one AirPod in: the AirPods battery
  entries show which buds are present.
- **Which states must be exact:** every state the owner's Mac can show. That covers:
  - AirPods connected or not, and their listening-mode rows;
  - charging or not, and Low Power on;
  - zero, one or several "Using Significant Energy" apps;
  - the owner's AirPlay targets;
  - light and dark.

  Device and app icons come from what Apple's panel exposes. Its Accessibility tree names the SF Symbol it uses, for
  example `airpods.pro.gen1`. A sensible generic symbol is the fallback. Both menu bar icons track their live state
  the way Apple's do: volume level and mute, output type, battery fill, charging, Low Power colour, and the percentage
  setting.
- **Apps section rows:** only processes that belong to a running app with a bundle and an icon, so regular apps and
  menu-bar-only apps. System daemons and helpers without an app of their own are folded into their app or left out.
  Safari and other WebKit apps show as rows that are dimmed, with "Can't be controlled yet", because their sound plays
  through a system process.
- **Ultra Low Power in Energy Mode:**
  - While the mode runs, only the Ultra Low Power row is checked. macOS's Low Power Mode is on underneath, but the
    menu shows the mode the person chose.
  - Choosing another Energy Mode while it runs ends the mode, waits for it to put things back, then applies the chosen
    mode, and records that as the person's choice. The row shows the new choice as soon as it is clicked.
  - Energy Mode from Anode's menu writes the same sources Apple's menu writes. Which sources that is gets measured
    first, by reading `pmset -g custom` after a press in Apple's panel.
- **Additions need their menu.** The Apps section, the charge limit row and the Ultra Low Power row are parts of their
  menu. Each one's Beta toggle sits under its menu's toggle and is greyed out while that menu is off.

## Owner's answers after the builder check

- **No menu, no per-app volume (owner).** If there is no menu to change an app's volume in, that app goes back to
  normal. This applies when the Sound menu is off, when per-app volume is off, and **when Anode quits**. The saved
  values are kept for the next time the menu is on. On a quit or a crash, every tap is gone, so every app sounds as it
  would without Anode.
  - A crash or `kill -9` must leave no app quieter or muted. Taps are private to Anode's process, so they end with it.
    Confirm this by ear in the hardware check.
  - The same rule applies to the Battery menu's additions. With the Battery menu off, the charge limit row isn't
    shown. Charge Control itself keeps working from its Beta Features section, because it existed before this menu.
- **No known bugs in a release (owner): "extra work it is. known bugs shouldnt go to release."**
  - **A muted app must be silent from its very first sound,** and an app set lower must be lower from its first
    sound. The November spike measured about 0.2 s getting through, because the tap was made after the app's sound
    process appeared. That gap is not acceptable.
  - The approach to measure first: macOS 26's `CATapDescription.bundleIDs` and `processRestoreEnabled`. A tap made by
    bundle id exists before the app plays. It "saves tapped processes by bundle ID when they exit, and restores them
    to the tap when they start up again", per the SDK header.
  - The spike must prove two things by measurement and by ear, before any app code:
    - a bundle-id tap made while the app is quit catches its first sound when it launches and plays;
    - a browser's helper processes are covered. Either their own bundle ids are listed, or the app's id covers them.
  - If it fails, the fallback to measure is one tap of everything except Anode, with every process's gain applied in
    one place. That routes all sound through Anode while any app is changed, so its latency and battery cost must be
    measured too.
  - **The same rule applies across the whole feature.** Anything found during building that would ship as a known
    bug either gets fixed or stops the release until the owner decides.
- **Icon position:** Anode adds its items. The person places them with Cmd-drag, and macOS remembers the place.

## Left to the builder

- How to draw the glass and match the materials exactly, and how to measure "exact": the overlay method, the
  tolerances, light and dark appearance *(builder's call: match both)*.
- Icons for the gear and the Ultra Low Power row, drawn in Apple's style.
- How the minus button shows that Soft Drain or Hard Drain is running.
- The code layout, following Anode's existing Beta Features and menu bar widget patterns.
