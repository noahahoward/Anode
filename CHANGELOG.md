# Changelog

Versions are `MAJOR.MINOR.PATCH`: the last number for bug fixes and speed or battery work, the middle number for a new
feature or a visible change in how something works, the first only for a rewrite or a break (see `CLAUDE.md`).
`VERSION` in `build-app.sh` is what About shows; the build number beside it is the commit count.

Nothing was bumped between 1.0.0 and 1.15.0. Those versions were assigned afterwards from the history and exist as
git tags (`git show v1.7.0`); builds made before 1.15.0 still say 1.0.0 in their About box.

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
