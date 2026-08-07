# Menu bar widgets never appear — investigation notes

## Symptom

Status items are created and look healthy by every available check:

- `NSStatusBar.system.statusItem(...)` returns an item
- `item.button` is non-nil, `button.frame` is correctly sized `(0,0,47,22)`
- `button.image` is a valid template image of the right size
- `item.isVisible == true`, `item.length == -1` (variableLength)
- Accessibility reports the right number of menu bar items

**But the status item's WINDOW is `(0, 0, w, 0)` — zero height, never
positioned.** A healthy item gets a real frame such as `(1397, 1130, 71, 39)`.
So AppKit never lays the items out, and the menu bar shows nothing while
every health check passes. That combination is what made this expensive to
find: `count menu bar items` returning 6 says nothing at all.

## The one diagnostic that matters

Do not trust counts, `isVisible`, or accessibility. Log this:

    button.window?.frame

Zero height means the item was never placed.

## Excluded by controlled experiment

Each of these was tested and is NOT the cause:

- Activation policy (`.regular` vs `.accessory`) — fails with either, and a
  minimal app using `.regular` **plus a real main window** works fine
- Rebuilding items after a policy change
- `autosaveName` position persistence — removing it changes nothing
- `item.isVisible` — already true; forcing it changes nothing
- Launch method — `open` and running the binary directly both fail
- Menu bar overflow — a SINGLE widget is hidden too, and there is ~450 pt free
- `killall SystemUIServer`
- A code regression — reproduced at the last known-good commit
- The template image path — a minimal app drawing the same kind of template
  image renders it fine
- The `.app` bundle and its ad-hoc signature — **the minimal probe binary
  running INSIDE the real BetterStats.app bundle works**, which rules the
  bundle out entirely
- `NSPrincipalClass` missing from Info.plist (added anyway; correct regardless)
- `LSUIElement`
- `MenuBarWidgetController` itself — a plain-title control item created
  directly in `AppDelegate` fails identically
- Repeated rebuilds — instrumented, exactly one rebuild on the main thread
- `buildMenu()` / a custom `NSApp.mainMenu`
- Eagerly constructed `NetworkPane`/`SensorsPane`/`FansPane` views (made lazy,
  no change)
- Timing within `applicationDidFinishLaunching` — the control item fails even
  as the very FIRST statement of it

## Where the cause must be

Since it fails as the first statement of `applicationDidFinishLaunching`, the
damage is done BEFORE that runs. That leaves:

1. `AppDelegate`'s remaining eager stored properties: `sysMetrics`
   (`SystemMetrics()`), `netAttribution` (`NetworkAttribution()`),
   `drain` (`DrainRateEstimator()`)
2. Top-level code in `Sources/BetterStatsApp/main.swift` before `app.run()`
3. Static/global initialisation inside PowerKit reached from those

## Next step

Bisect (1). Comment out those stored properties one at a time and watch
`button.window?.frame`. The reference that WORKS, for comparison, is
`/tmp/sbtest/reg.swift` — a `.regular` app with a window and one status item.

The probe technique is the useful part: copy `BetterStats.app`, replace
`Contents/MacOS/BetterStatsApp` with a test binary, re-sign ad-hoc, and run it
directly from inside the bundle. `open` fails with `-10825` on a swapped
binary; launching the executable path directly works.
