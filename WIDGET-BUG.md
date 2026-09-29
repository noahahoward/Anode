# Menu bar widgets never appeared — RESOLVED

## Cause

**Accumulated LaunchServices registrations for the build directory path.**

Rebuilding an ad-hoc-signed bundle repeatedly at one path piles up
registrations for that path — 29 of them for `dev.anode.app` by the time
this was found. Past some point macOS stops laying out that app's
`NSStatusItem`s. They are still created, still hold correctly sized buttons and
valid template images, and still report `isVisible == true`; their status
windows simply sit at `(0, 0, w, 0)` — zero height, never positioned — forever.

Nothing in the app is wrong. Nothing reports an error.

## Proof

Byte-identical bundles (`diff -r` clean), same signature, same binary, same
minute:

    /tmp/verify.app                      first item at (1399, 7)     renders
    <build dir>/Anode.app          first item at (-1, 1157)    invisible

`~/Applications/Anode.app` also renders. So does every fresh path tried.
Only paths the build had churned were affected.

## Fix

`build-app.sh` now installs to `~/Applications` and prints which copy to
launch. That path is stable because the build does not rewrite a bundle there
on every run, which is also what a real user's install looks like.

`lsregister -kill -r` would clear the database, but Apple removed `-kill`;
`lsregister -u <path>` does not undo it either.

## The diagnostic that matters

Do not trust item counts, `isVisible`, image sizes, or accessibility — all of
them reported healthy throughout. Log this:

    button.window?.frame

Zero height means the item was never placed. That single line would have found
this in minutes.

## Ruled out along the way

Each excluded by controlled experiment, not reasoning: activation policy
(`.regular` vs `.accessory`), rebuilding items after a policy change,
`autosaveName`, `isVisible`, launch method (`open` vs direct), menu bar
overflow (a single widget failed too), `killall SystemUIServer`, any code
regression (reproduced at the last known-good commit), the template image path,
`NSPrincipalClass`, `LSUIElement`, `MenuBarWidgetController` itself (a plain
`button.title` item created directly in `AppDelegate` failed identically),
repeated rebuilds (instrumented: exactly one, on the main thread),
`buildMenu()`, eagerly constructed pane views, construction timing within
`applicationDidFinishLaunching`, SwiftPM vs `swiftc`, linking PowerKit,
deployment target (tested at minos 13, 14, 26, 27, 28), spaces in the path, the
Downloads folder, `com.apple.provenance`, and `/Applications` as an install
location.

Two of those deserve a note because they nearly misled the investigation. A
`swiftc` probe defaults to a minos ABOVE the running OS, so it launches only
when executed directly — `open` refuses it with `-10825`. And the profiler's
`sample` counts where threads *are*, not where CPU is spent, so a thread
blocked in `waitpid` looked like the dominant cost when it consumed nothing.

---

# Widgets never appeared on a MacBook Neo — a second cause

## Cause

**The menu bar was full.** A MacBook Neo (`Mac17,5`, 13", no notch) has a much
shorter menu bar than the 16" this app was built on. macOS packs status items
right to left and, when they reach the left end, **drops the rest without an
overflow menu or an error** — and a freshly launched app's items are always the
leftmost. The same happens behind the notch on notched MacBooks. As in the
first bug, every property the app sets still reads healthy.

Worse, the app then went `.accessory` when its window closed, on the assumption
that a created widget is a visible one. With the widgets dropped that left no
window, no Dock tile and no menu: running, and unreachable.

## Fix

`MenuBarWidgetController` now looks at where macOS actually put each item
(`button.window.frame`, the diagnostic this file already called the one that
matters) and squeezes until they fit:

1. **full** — as configured;
2. **compact** — labels dropped, roughly 40 % narrower;
3. **single** — one item: the app's glyph plus the first widget's reading,
   opening the panel, which carries every reading plus Open and Quit.

If even the single item is not placed, the app keeps its Dock tile, opens the
window once and says why (menu bar full, or switched off under System
Settings › Menu Bar › Allow in the Menu Bar). Settings › Menu Bar shows the
same verdict live.

An item counts as shown only if its window is ordered in (`isVisible`) AND
its frame has height, lies on a screen and clears any notch. The first catches
the Neo's usual case — on a short bar the frontmost app's own menus (Finder's
included) run into the status items and macOS takes the ones they reach off
screen — and the second catches the never-placed and parked-off-screen cases.

The look is deferred while Anode itself is frontmost, because its own menus
hide whatever status items they reach — which says nothing about the bar — and
repeated when any app becomes frontmost, on screen changes, and every 30 s
while anything is hidden. The alert can be switched off for good; Settings ›
Menu Bar keeps the same verdict. The rule that reads a frame is pure and pinned
in `WidgetPlacementTests`.
