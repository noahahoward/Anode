# Changelog

Versions are `MAJOR.MINOR.PATCH`: the last number for bug fixes and speed or battery work, the middle number for a new
feature or a visible change in how something works, the first only for a rewrite or a break (see `CLAUDE.md`).
`VERSION` in `build-app.sh` is what About shows; the build number beside it is the commit count.

Nothing was bumped between 1.0.0 and 1.15.0. Those versions were assigned afterwards from the history and exist as
git tags (`git show v1.7.0`); builds made before 1.15.0 still say 1.0.0 in their About box.

## 1.18.10 — 2026-11-13
- Automatic updates: if the folder Anode was built from sits in Downloads, Desktop or Documents and was moved or renamed, the check Anode makes when it opens was skipped from then on, with the setting still showing on and nothing saying why. Anode now reads the folder again the first time its window opens (macOS may ask for permission then), and from the next launch the check runs by itself again.

## 1.18.9 — 2026-11-13
- Ultra Low Power Mode: the confirm box now says which apps will be left running because a part of them cannot be frozen ("Leaves Backup and VPN running: each has a part Anode cannot freeze."). Before, such an app was in neither the kept nor the frozen list, and its still running after Confirm looked like a mistake.

## 1.18.8 — 2026-11-13
- Menu bar: the pair of watts shown on the charger (for example 12/0.5W) is now captioned "Used/Charger": the first number is what the Mac is using and the second is what the charger is supplying. The caption used to be "Power", which named neither, and during a drain to the limit the pair was easy to read as the battery being charged.

## 1.18.7 — 2026-11-13
- The closing lines of an install or update said "fan control" where they meant the Anode helper. They now name the helper, say what uses it (fans, Charge Control and Low Power Mode), and say that Anode offers to install it the first time it opens; the commands for running it by hand and for undoing it are still there.

## 1.18.6 — 2026-11-13
- Running Anode's tests (./test.sh) no longer leaves files behind: test settings are kept in memory, where each run used to leave hundreds of empty com.anode.tests files in ~/Library/Preferences.
- A test run no longer writes into Anode's own folder in Application Support (a line had appeared in the real Keep Awake log, and the folder was made again on a Mac where Anode was uninstalled): in a test run Anode's files go to a temporary folder that is removed when the run ends.
- Nothing changes in how the app itself works.

## 1.18.5 — 2026-11-13
- Anode now quits when it is asked to while one of its own questions is on screen. Before, with the first-run question about automatic updates or the helper notice up, the updater and the uninstaller found Anode still running on a freshly installed Mac, and logging out was held up.
- A question that was closed this way counts as not answered: the one about automatic updates is asked again the next time Anode opens.
- The updater and the uninstaller ask Anode to quit by its identifier, so another copy of Anode.app on the Mac is never reached instead, and the updater waits for Anode to be gone before replacing it.

## 1.18.4 — 2026-11-13
- Pause When Hot: the temperature it starts at is now 40 °C, not 35 °C. Batteries are built to charge up to 45 °C and age faster the warmer they charge, but a MacBook's battery sits in the low 30s at light load and passes 35 °C under ordinary work, so 35 °C paused charging on a Mac that was only doing its job. 40 °C pauses for real heat and still well before the limit.
- A temperature you set yourself is kept. The Pause When Hot tooltip says where the number comes from.

## 1.18.3 — 2026-11-13
- Pause When Hot: closing the lid on a warm Mac used to leave charging paused until the Mac was next opened, because nothing reads the battery's temperature while it sleeps. With the Anode helper installed, the Mac is now woken half an hour later, and charging resumes to your limit if the battery has cooled; if it is still hot it is paused again and tried again half an hour after that.
- Without the helper nothing can wake the Mac, so the pause is set aside while the Mac sleeps and the battery charges as usual; the pause is back as soon as the Mac wakes.
- A battery that was hot when the Mac went to sleep and is cool when it wakes is no longer paused for another five minutes after the wake.

## 1.18.2 — 2026-11-13
- Charge Control: on a Mac where Anode cannot use the folder every account shares (/Users/Shared/Anode), it used to keep a private record of macOS's charging settings instead. With two accounts using Charge Control that could leave one account's limit in force after both had quit Anode. It now holds no limit on such a Mac and says why in its section; turning Charge Control off and on tries the folder again.
- A limit left by an earlier version on such a Mac is still put back the next time Anode opens, and a record that is lost while a limit is held no longer leaves the limit in force after a quit.

## 1.18.1 — 2026-11-13
- Charge Control: if Anode crashes or is force quit while it holds a limit, macOS's own charging settings are put back within a few seconds, by a small watcher that runs beside Anode while Charge Control is on. Before, the limit stayed in force until Anode was next opened, which could be never.
- The next time Anode opens after that it still waits a minute before holding a limit again, as before.

## 1.18.0 — 2026-11-13
- The Anode helper is offered as soon as Anode is installed or updated: the first time it opens, one notice says what the helper does (one helper for fans, Charge Control and Low Power Mode), then macOS asks for your password.
- Nothing appears when the helper installed is already current, and "Not Now" is not asked again until the next update. The buttons in the Fans tab, Charge Control and Ultra Low Power Mode still install it later.

## 1.17.0 — 2026-11-13
- Charge Control (Beta Features, off by default): hold the battery at a charge limit you choose, from 20% to 100%. The limit applies while Anode is running: quitting Anode, or turning Charge Control off, puts macOS's own charging settings back as they were, and opening Anode again brings your limit back.
- If Anode ever stops without quitting, the next time it opens it lifts the limit first and waits a minute before setting it again, so an Anode that is not working does not hold your battery.
- Ready By: choose a time of day, and while the Mac is plugged in Anode holds the battery where it is, then charges it so it is at your limit by that time. It only waits when the time is within the next 12 hours, never waits below 30%, and wakes a sleeping Mac once to start charging.
- Drain to Limit runs the Mac from the battery down to your limit while it stays plugged in, and Charge to Full charges to 100% once and returns to your limit when you unplug.
- Drift Below the Limit lets the battery fall a few percent below the limit before recharging. Pause When Hot pauses charging while the battery is hot. Hold Level During Sleep keeps the level where it is while the Mac sleeps, and Drain Automatically Above the Limit drains whenever the battery is above the limit.
- Limits other than 80, 85, 90, 95 or 100%, draining and Ready By need the Anode helper (the same one the fans use). The helper reconnects the charger when Anode quits, before the Mac sleeps and when the cable is pulled, and a helper that was stopped part-way reconnects it when it next starts.
- The main card's "charging to" and "held at" lines follow Charge Control's limit while it is on.
- Uninstalling Anode puts macOS's own charging settings back before anything is removed, and stops if Anode is still running.
- Ultra Low Power Mode (Beta Features, off by default), for when the battery has to last: press Start (or ⌃⌥⌘U), then Confirm, and Anode freezes every app and background tool except the app in front, the ones you list to always keep, and macOS's own. Frozen apps come back exactly where they were when you turn it off, and clicking one in the Dock brings it back early.
- While it is on, what still runs is kept on the efficiency cores, the screen is held at a quarter brightness or lower and set to its lowest refresh rate, the desktop behind your windows goes black, the keyboard light goes off, macOS's Low Power Mode is switched on, and Anode's own measuring pauses (the menu bar readings say "Paused").
- Only you turn it on and only you turn it off. Turning it off, quitting Anode, or Anode stopping unexpectedly puts everything back: the apps continue, and the brightness, refresh rate, keyboard light and Low Power Mode return to what they were.
- An app with a part Anode cannot freeze is left running whole, and an app on a call is taken off the efficiency cores. No running time is promised. Measured on a 14-inch MacBook Pro: freezing a busy background app took the Mac from 7.5 W to 3.2 W, and keeping heavy work on the efficiency cores from 27 W to 5 W; at rest, only the darker screen saves anything.
- One helper for everything: the fan helper is now called the Anode helper, and the same one does fans, Charge Control and Low Power Mode. Install it again once after this update (Install Anode Helper… in the Fans tab, Charge Control or Ultra Low Power Mode) so it can switch Low Power Mode on; fans and Charge Control keep working with the one you have until then.
- Installing or removing the helper from any of those places is noticed by the others within a few seconds.
- Uninstalling Anode now removes everything: the Anode helper and the Always Stay Awake permission go too (the uninstaller's Terminal window asks for your password once), along with the caches, crash records and test files it used to leave. It also resets Anode's privacy approvals, so a reinstalled Anode asks for Accessibility and Screen Recording again.

## 1.16.0 — 2026-11-11
- Menu bar hider (Beta Features, off by default): a chevron in the menu bar tucks other apps' icons out of sight, leaving macOS's own icons (Wi-Fi, sound, battery, the microphone light and the rest) and the ones you choose to keep. Press the chevron (or ⌃⌥⌘B) and a small panel under the notch shows the rest, each one clickable.
- Icons macOS had parked off the left edge when the bar got too full (they could not be seen or clicked) are reachable from the panel too.
- Choose what stays on the bar and what sits behind the chevron by dragging, in Beta Features. Anode's own menu bar widgets can be tucked away the same way.
- Right-click the chevron to pick how long the panel stays open (5, 10 or 30 seconds, or until you close it). Turning the feature off, or quitting Anode, puts the bar back as it was.
- Installs and updates now check that the copy of Anode that is running is the copy just installed, and restart it if not (a stale copy made the fan helper refuse the app).

## 1.15.0 — 2026-11-11
- Keep Awake with the lid shut no longer makes Anode draw for a screen nobody can see (it had used 400–600 mW for the whole session). The live wallpaper pauses then too.
- The open window uses less CPU: fonts are shared, unchanged table cells are not redrawn, measured column widths are remembered.
- Opening a group in the Sensors list no longer lights every row as hovered.
- The update screen shows the version and two plain sentences about the update. Versions are numbered by the convention above.

## 1.14.1 — 2026-11-10
- Permissions survive updates (builds are signed with a stable local identity), and a Reset button re-asks for a stuck approval.
- Fixed the crash when the window switcher went to one of Anode's own windows; runs that end without a crash report are logged.
- Install builds on older Swift compilers, and a failed install removes everything it made. Installs and updates build about twice as fast.

## 1.14.0 — 2026-11-09
- Game mode: a small strip of live readings over full-screen games, with a hot corner to show it in any app.

## 1.13.0 — 2026-11-06
- Live wallpapers: video, image, web page or video link as the desktop, on any display, pausing when covered, locked, on battery or in Low Power Mode.

## 1.12.0 — 2026-11-06
- Keyboard cleaner: lock the keyboard and trackpad and black out the screen while you wipe them.

## 1.11.0 — 2026-11-05
- Keep Awake: Never Sleep and Always Stay Awake (lid closed) from a menu bar icon. Fixed a freeze when Anode moved its own windows.

## 1.10.0 — 2026-11-04
- Lid Glass: a frosted-glass fold effect that follows the lid as it closes.

## 1.9.0 — 2026-11-03
- Dock previews list an app's windows on other desktops too.

## 1.8.1 — 2026-10-31
- Mouse and shortcut taps run on their own thread; a setting stops the menu bar widgets collapsing when the bar looks full.

## 1.8.0 — 2026-10-30
- Desktop switcher, window actions (halves, thirds, maximize and more), window groups, drag-to-edge snapping, and changeable keyboard shortcuts.

## 1.7.0 — 2026-10-29
- Window switcher with previews, and Dock window previews (both off by default).

## 1.6.0 — 2026-10-27
- Menu bar backdrop (blur or solid) and a Beta Features window; Anode Stats under Developer Tools; widgets remember their layout per app and display.

## 1.5.0 — 2026-10-20
- Choose the lines on the history graph; a load-following time left beside the steady one; watts used and supplied on the AC widget.

## 1.4.0 — 2026-10-13
- Optional automatic update at launch behind a progress window; a recent drain rate beside the all-time one.

## 1.3.1 — 2026-10-07
- Recovers a stranded window; stops raising consent prompts for folders nobody asked it to read.

## 1.3.0 — 2026-09-29
- Time left from what this Mac usually draws, a Forecast Check window that compares it with real discharge, and correct readings on every Mac including the MacBook Neo.

## 1.2.1 — 2026-09-10
- Fan control started again (launchd binds its socket somewhere else).

## 1.2.0 — 2026-09-04
- The SSD's own health counters, swap and drive health for the menu bar.

## 1.1.0 — 2026-08-18
- The menu bar panel is grouped by subject and can be rearranged; it samples live while it is open.

## 1.0.0 — 2026-08-13
- First release.

## 0.2.0 — 2026-08-08
- First numbered build.
