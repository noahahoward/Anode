# Ultra Low Power Mode: design

## Intent

A request reached the owner from someone who was at 10% battery, could not plug in, and needed the Mac to last a 1.5 to 2 hour meeting while coding. The only thing they needed running was their code editor.

The owner's brief: "an ULTRA low power mode. I'm talking kill all background procs that are not system, basically stopping anode measurements, and if possible lowering screen refresh rate further than standard macos low power mode, all of that in addition to standard macos low power mode."

So: one switch that strips the Mac down to the one app the person is using. Everything else of theirs stops drawing power, the screen is held dim and slow, macOS's own Low Power Mode is on, and Anode itself goes quiet. When they switch it off, everything is exactly as it was.

The hard part, in the owner's words: "What to kill, and what not to kill. If there are apps open we cannot risk killing procs they need, but we need to kill procs that aren't needed."

## Decisions the owner made

- **Freeze, not kill.** ("freezing sounds good") A stopped process uses no power, loses nothing, and continues where it stopped. A wrong call then costs a frozen app, not lost work.
- **Only manual on, only manual off.** ("ONLY manual on, and ONLY manual off.") No trigger at a battery level, and plugging in the charger does not end it.
- **Start is one confirm button.** ("confirm button, and that's about it.")
- **Brightness:** "1/2 of max as the new max."
- **Refresh rate:** the lowest each Mac's own screen can do. ("this needs to be compatible with all; lowest rate possible per each macbook.")
- **Anode while it is on:** "anode should pause all measurements, just show paused for drain, left, swap, ram, cpu, everything in menu bar, all background measurements, only measure if main window open."
- Approved as proposed ("all looks good to me"): what is kept; apps opened afterwards are left alone; one app can be un-frozen from Anode's menu; frozen apps' windows are hidden; macOS Low Power Mode on through the helper and put back afterwards; the switch lives in Beta Features, Anode's menu and a shortcut; quitting Anode ends the mode; a crash is cleaned up.

Decisions beyond these are marked *(author's call)*.

## States

- **Off.** Nothing of this feature exists: no observers, no timers, no helper process.
- **Confirming.** The owner asked for the mode; a small box says what will be kept and how many apps will be frozen, with Confirm and Cancel. Nothing has changed yet.
- **On.** Everything in "What the mode does" is in force until the owner turns it off or Anode quits.

There is no other way in or out. Sleep, wake, the charger, a full battery and a display change do not end the mode. After a restart of the Mac the mode is Off *(author's call: the frozen processes no longer exist; Anode's next launch puts the screen and power settings back)*.

## What the mode does

### 1. Freezes what is not needed

Every process is in exactly one of three piles.

**Kept** (never touched):
- The app in front when Confirm is pressed.
- The apps on the "always keep" list, which the owner edits in the Beta Features section (empty to begin with; meant for things like a VPN client or a meeting app).
- **Everything that belongs to a kept app:** the processes inside its bundle, every descendant of those, and every process macOS holds that app responsible for. Measured on the owner's Mac: the tools run from an editor's terminal (shells, interpreters, language servers, command-line assistants) are all descendants of the editor. Freezing them would break the very work the mode exists to protect.
- Any app the owner opens or brings forward after the mode started (see "Getting an app back").

**Never touched, whatever the lists say:**
- Processes not owned by the logged-in user (Anode could not signal them anyway).
- macOS itself: every process that is not an app the owner opened. In practice, processes whose executable lives under the system's own locations, and the system's interface agents (the Dock, the menu bar, Control Center, Finder, the window manager, input methods and the like). Measured: 546 of these on the owner's Mac, about 0.5 W together; they are not safe to stop.
- Anode, its helper, and the watchdog described under "Safety".
- App extensions that macOS hosts on behalf of an app (Finder sync extensions, widgets) *(author's call for v1: left alone; whether freezing them is safe is unmeasured)*.

**Frozen:** everything else of the user's.
- Apps with a Dock icon that are not kept, **including Apple's own apps** (a browser, mail, music). The line is "an app the owner opened" against "a background service of macOS", not Apple against everyone else: the first sort put Apple's developer tools in the wrong pile.
- Menu bar apps and other windowless apps of other vendors.
- Other vendors' background agents (sync clients, updaters, launchers).
- With each of these, everything that belongs to it, by the same rule as for kept apps. An app is frozen whole or not at all.

Before an app with windows is frozen, Anode hides it, so the owner is not left clicking a dead window. The windows come back when the app does.

### 2. Getting an app back

- Anode's menu lists the frozen apps while the mode is on. Choosing one un-freezes that app and everything that belongs to it, and it stays un-frozen for the rest of the session.
- Bringing a frozen app forward (its Dock icon, the app switcher) un-freezes it *(author's call; it follows from "apps you open afterwards are left running". Whether macOS reports the activation of a stopped app is unmeasured; if it does not, the menu is the only route and the section says so)*.
- Apps launched after the mode started are never frozen.

### 3. Holds the screen down

- **Brightness ceiling at half.** If the screen is brighter than half of the slider when the mode starts, it is set to half. While the mode is on, anything that raises it above half (the keys, auto-brightness) is pulled back to half. Going dimmer is always allowed. At the end the earlier brightness is put back, but only if the mode lowered it and the owner has not chosen a lower one since.
- **Lowest refresh rate.** The built-in display is asked for the rates it offers at the current resolution, and the lowest is used. Nothing is hard-coded, so a model with a lower rate works without an update. On a screen that offers only one rate, nothing changes and the section says so. External displays are left alone *(author's call)*. The earlier rate is put back at the end.
- **Keyboard backlight off** while the mode is on, put back at the end *(author's call; drop it if there is no clean way to do it)*.

### 4. Turns on macOS's own Low Power Mode

Through Anode's existing root helper, as one new command; the earlier power mode is recorded and put back at the end. If the helper is not installed, or is an older one that does not know the command, this part is skipped, the mode does everything else, and the section says so with the button that installs the helper.

### 5. Quiets Anode

- All background measuring stops: the samplers, the history recording, and anything else that wakes on a timer to measure.
- Every reading in the menu bar shows "Paused" in place of its number.
- While Anode's main window is open, measuring runs as it normally does; closing the window pauses it again.
- Consequence the owner accepted: the history has a gap for the time the mode was on, except while the window was open.
- Other Beta features that draw or poll on their own (live wallpaper, the game strip) are paused for the session *(author's call)*; features that only react to events keep working.

## The switch

- **Beta Features section "Ultra Low Power Mode":** the button that starts and ends the mode; the "always keep" list (add and remove apps); a line for each part that cannot work on this Mac (no helper, one refresh rate only); and the honest note below.
- **Anode's menu:** "Ultra Low Power Mode…" when off; when on, "Turn off" and the list of frozen apps.
- **A shortcut**, changeable in the Shortcuts window like the others *(author's call: propose ⌃⌥⌘U if it is free)*.
- **The confirm box:** one or two lines, for example "Keeps: the app in front and 2 always-kept apps. Freezes 9 apps until you turn this off." Confirm and Cancel. No list to tick.
- **The honest note** in the section: what was measured (below), in plain words. Dimming further is what saves the most; the refresh rate saves little or nothing; frozen apps lose their network connections; no running time is promised.

## Safety

A stopped process stays stopped until something continues it, whether or not Anode is still alive. So:

- **Quitting Anode ends the mode**: everything is continued and every setting is put back before Anode exits. The same at logout, restart and shutdown, as early as macOS announces them: a frozen app cannot answer the request to quit and would hang the logout.
- **A crash or a kill of Anode must not leave apps frozen.** Anode keeps a record on disk of what it froze (process id plus start time, so a recycled id is never signalled) and of each setting it changed and its earlier value. A small watchdog continues everything at once if Anode dies *(author's call: a child process of Anode that waits for its parent to exit; it needs no root because the processes are the user's own. The builder may choose another mechanism that gives the same result)*. At its next launch Anode reads the record, continues anything still stopped, and puts the settings back.
- **The helper leaves nothing behind**: if Anode quits or breaks while Low Power Mode was switched on by this feature, the earlier power mode is restored (the owner's standing rule for the helper: the Mac is released, not held).
- **Only what Anode froze is ever continued**, and only what this feature changed is ever put back.
- A frozen process is never killed, by any path.

## What was measured (2026-11-12, owner's 14" MacBook Pro, on battery)

Probes are throwaway and live in the session scratchpad; the numbers that matter are here.

- **Where the power goes**, last 24 hours on battery (6.6 h, Anode's history): whole Mac 9.9 W (15% an hour). All apps' processor use about 1 W (two tallies gave 0.7 and 1.5). Graphics about 2.5 W. Screen, radios, storage and baseline 6.7 W.
- **The target.** 10% lasting two hours is 5% an hour, about 3.5 W on this Mac (assuming a battery near 70 Wh, inferred, not read). Over a week on battery the Mac was under 4.25 W a tenth of the time and under 3.2 W almost never.
- **Brightness** (whole-Mac power, 60 s each, processor steady at 0.4 to 0.7 W): slider at half 4.3 W; full 10.4 W; a quarter 2.8 W. Brightness is the largest lever by far.
- **Refresh rate.** The built-in display offers 120, 60, 59.94, 50, 48 and 47.95 Hz. Holding 47.95 Hz at half brightness read 4.6 W against 4.1 to 4.5 W either side: no saving that can be measured. Setting the rate for the life of one process applied system-wide and went back by itself when the process ended, including when it was killed, which suits the safety rules. Other models: 14" and 16" MacBook Pro screens offer the same list; every MacBook Air and the MacBook Neo are 60 Hz only (maker's pages and spec sheets).
- **The piles.** 1,002 processes: 349 not the user's; 546 the user's but part of macOS; 107 from 26 other apps and tools. Only four of those were busy. The rest sat at zero, so freezing them saves nothing while they are idle: the frozen set cost about 0.1 to 0.3 W. What freezing buys is the end of bursts: a build in another window took the Mac from 4.5 W to between 10 and 17 W during the run.
- **Freezing itself**: 30 processes were stopped and continued twice, 75 s each, with no visible harm. The power readings for those stages are unusable (the build above), so whether freezing makes a kept process misbehave is **not measured**.
- **Not measured:** what Low Power Mode saves; whether a kept process spins when a peer is frozen; whether macOS reports the activation of a stopped app; logout with stopped apps; extensions of frozen apps; the keyboard backlight.

## Goals

- At half brightness with nothing else busy, the Mac sits near its floor (about 4.3 W measured here), and stays there because nothing in the background can start a burst.
- Nothing is lost: turning the mode off returns every frozen app, the brightness, the refresh rate, the power mode and Anode's measuring to what they were.
- Works on every Mac Anode supports; each part that a Mac cannot do is skipped and named.
- One button to start, one to stop.

## Non-goals and anti-goals

- No automatic start or stop. No killing. No promise of a running time.
- Not a per-app throttle and not a scheduler: an app is running or frozen.
- **Anti-goals** (the feature has failed if any of these happens):
  - work is lost, or an app is left frozen after the mode has ended or Anode is gone;
  - the kept app breaks because something it needs was frozen, with no way to see it and get it back;
  - the Mac is left dim, slow or in Low Power Mode after the mode has ended;
  - a logout or shutdown hangs on a frozen app;
  - the mode makes the Mac draw more than before (a kept process spinning because a peer is frozen);
  - the section claims a saving that was not measured.

## Constraints

- macOS 13 deployment target; no new dependencies; a Beta Features section, off until the owner starts it.
- No other product's name, and no feature name coined by another product, in code, interface text, tests, commit messages or documents.
- One root helper, one pattern: the power-mode command is added to the existing helper (a new command, a protocol version step, and the disclosure text that tests pin), not to a second one. Those files are changing in the charge feature that is landing as 1.17.0, so this feature is built on top of that once it is stable.
- Tests never send a real signal to another process, change the real brightness, refresh rate or power mode, or read or write the real settings store. Every one of those sits behind a protocol with a fake; the real thing runs only in hardware steps with the owner at the Mac.
- Every call into another app or the system that can block runs off the main thread with a timeout; Anode has frozen on such calls before.
- Subagents used for the build run on the smaller model, one implementer and one reviewer per task (the owner's standing instruction).

## Left to the builder

How "belongs to" is computed and how fast; how the frozen set is kept current when a kept app starts new helpers; the watchdog mechanism; how brightness changes are noticed; where the record lives and its format; the shortcut; the exact words in the confirm box and the section; which of Anode's own timers count as measuring.

## Open risks (each gets a measured step in the plan before anything depends on it; all need a quiet Mac)

1. Freezing may make a kept process, or macOS's own hang reporting, burn power. Measure whole-Mac and per-process power with the set frozen for several minutes.
2. Low Power Mode's saving on top of the rest is unknown, and so is whether the target is reached with all parts on.
3. macOS may not report that a stopped app was brought forward.
4. Hiding an app is asynchronous: it must have hidden before it is stopped, or its windows stay as dead pictures.
5. Logout, restart and sleep with stopped apps.
6. Brightness: whether the ceiling can be held against auto-brightness without flicker.
