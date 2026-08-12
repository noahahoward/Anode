# Menu bar widgets never appeared — RESOLVED

## Cause

**Accumulated LaunchServices registrations for the build directory path.**

Rebuilding an ad-hoc-signed bundle repeatedly at one path piles up
registrations for that path — 29 of them for `dev.noah.anode` by the time
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
