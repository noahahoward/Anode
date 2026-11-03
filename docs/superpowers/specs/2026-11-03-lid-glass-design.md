# Lid Glass — design

A new Beta Features section for Anode. As the MacBook lid closes, the screen appears to stay where it is
while it frosts over like glass, blurring progressively from the top edge toward the hinge. After the Mac is
unlocked, the desktop clears from a frosted state. It recreates the effect of the Mac Duo family of apps.

## Why

Anode is a utility app and must stay very low on CPU. This feature is wanted anyway, because it is a visual
touch the owner wants on their own Mac. The design goal is therefore that it costs almost nothing while
idle and spends its resources only in the roughly one second a close takes. Low CPU must not produce a
worse-looking effect: the visual quality target is "as good as possible", realistic frosted glass.

## Goals

- An on/off toggle in Settings → Beta Features, off by default, in the same shape as the existing
  `BetaFeature` sections (see `Sources/AnodeApp/BetaFeaturesWindow.swift`, e.g. `DesktopSwitcherFeature`).
- While off, nothing runs: no polling, no timers, no capture.
- A closing effect driven by the real lid angle: a frozen picture of the built-in display, blurred more
  toward the hinge as the angle falls, with realistic glass (see "Glass look").
- An opening effect after unlock: the desktop starts frosted and clears over a short time.
- Smooth at the display's refresh rate (up to 120 Hz) even though the sensor reports about 10 times a second.
- Effect disappears cleanly when the lid reopens before it closes completely, when the display configuration
  changes, or when the feature is turned off.

## Non-goals

- Anything drawn on the lock screen. The owner's Mac locks when the lid closes, and an ordinary app cannot
  draw there. The opening effect therefore plays after unlock and is not driven by the hinge.
- Private APIs (SkyLight and similar). One of the reference apps uses them to draw over the lock screen; we
  do not.
- External displays. Built-in display only.
- Macs without a lid-angle sensor. They see "not supported on this Mac" and the toggle does nothing.
- Tunable look. There are no sliders for the shader: it is tuned by the author to be as good as possible.
- Audio, dimming, or any other reaction to the lid.

## Anti-goals

- A visible jump when the effect starts. The overlay must be indistinguishable from the live screen at the
  moment it appears.
- Measurable idle cost. A user who leaves the toggle on should not be able to see it in Activity Monitor.
- Hanging the app. Sensor reads block; they never run on the main thread.

## Decisions made with the owner

- **Idle polling rate is user-adjustable, 4–30 Hz**, one slider in the feature's section.
- **At the trigger angle the polling rate goes to 120 Hz** and stays there until the effect ends.
- **Trigger angle is user-adjustable** (the angle at which the frozen picture appears and blurring begins).
- **The screenshot must stay at the trigger angle.** Meaning (the author's reading, to be confirmed in
  review): the picture shown is the one captured at, or just before, the trigger angle, and from the trigger
  onward it is frozen; the screen appears to stay in place while the lid moves. Because the trigger is
  adjustable, capture must be taken early enough for any allowed trigger angle.
- **Opening effect plays after unlock**, not on the lock screen.
- **No shader sliders.**

## Measured facts that shaped the design

All measured or read on the owner's machine (Mac17,9) on 2026-11-03 unless marked as from other projects.

- The lid-angle sensor is a HID device: vendor 0x05AC, product 0x8104, usage page 0x20, usage 0x8A. Reading
  feature report 1 returns three bytes: report ID, then angle in whole degrees, little-endian. It works
  unprivileged. The first read returned 107°.
- It must be polled; it sends nothing on its own (stated by macTilt's author).
- The hardware updates about 10 times a second and reports whole degrees (stated by the Mac Duo author's
  probe tool).
- Cost of polling, measured with a throwaway headless probe, as a share of one core: 4 Hz 0.16%, 8 Hz 0.29%,
  30 Hz 1.0%, 120 Hz 2.9%. A single read takes about 2 ms and at worst about 5 ms. Figures include the
  probe's own loop overhead, so they are slightly high.
- The other lid apps decouple sensor rate from draw rate: they run the 10 Hz readings through a critically
  damped spring and draw on a display link, with the Metal view paused otherwise.
- Anode already uses ScreenCaptureKit one-shot screenshots (`WindowEdgeSampler.swift`) behind
  `#available(macOS 14.0, *)` and `ScreenRecordingAccess.isGranted`; the package target is macOS 13.
- Screen Recording permission is already granted on the owner's Mac.

## Behaviour

**Idle (lid open, above the prewarm angle).** Poll at the user-set rate (4–30 Hz, default 8 Hz — the
author's call). Nothing else runs.

**Capture (default: at the trigger).** The first implementation task measures how long a ScreenCaptureKit
one-shot takes inside Anode. If it is short enough to take the picture when the trigger is detected without
a visible delay or jump, capture only then; there is no prewarm and no staleness. Only if the measurement
says it is too slow, add **prewarm**: screenshots about every 0.2 s, replacing the held one, but only while
the lid is moving downward inside a zone above the trigger (never merely because the angle is in the zone),
dropping the held picture when the lid stops or rises. The prewarm margin is derived from the idle poll rate
(angular speed x poll interval) so a fast close cannot skip past it.

**Arming.** The effect starts only when the lid moves downward through the trigger angle with real speed. A
lid resting below the trigger angle (people work at 100-120 degrees) never starts it, and the same stillness
logic stops it re-triggering while the lid sits still. Reference apps solve this with a stillness check
(Mac Duo) or a resting reference angle (cladofold).

**Active (angle at or below trigger).** Polling goes to 120 Hz. The overlay appears showing the held
picture, and a display link drives a spring that follows the sensor angle. The blur amount is a function of
the smoothed angle: none at the trigger, maximum at fully closed. The display link and the 120 Hz polling
run only in this state.

**Reopen before closing.** If the angle rises back through the trigger, play the clearing animation back to
the live screen, remove the overlay, and return to idle polling.

**Lid fully closed.** The Mac locks and sleeps; Anode does nothing more. On wake nothing from the closing
effect remains on screen.

**After unlock.** On the unlock notification, capture the live desktop, show the overlay fully frosted, and
clear the frost over a short time (about 0.5 s, the author's call), then remove the overlay. If the
capture fails, skip the effect silently.

**Turning the feature off, display changes, or sleep** while active: remove the overlay immediately, stop
the timers.

## Glass look

Target: realistic frosted glass, not a generic gaussian blur. Quality is the goal; cost is bounded because it
runs for about a second. The author's starting model, to be tuned against reference renders:

- Progressive blur: strongest at the top edge, far from the hinge (the hinge is at the bottom of the screen and stays sharpest, as the far edge of a tilting pane goes out of focus), and growing with closing angle.
- Refraction: sample positions displaced following Snell's law across a gently curved pane.
- Fresnel (Schlick) edge brightening, a faint chromatic dispersion between colour channels.
- A slight thickness tint and fine noise to prevent banding.

Cheap blur technique to try first: a mipmapped copy of the screenshot sampled at a per-pixel level of detail,
in one pass.

Tuning method: build a small standalone harness that takes a screenshot and an angle and writes images, and
compare against reference stills rendered in Blender (Cycles, rough transmission glass, IOR about 1.5). Blender
is a reference only; nothing from it ships.

## Constraints

- Swift; AppKit overlay window with a Metal view; ScreenCaptureKit for capture; IOKit HID for the sensor.
- macOS 14 or later for the feature (gated), because of the one-shot screenshot API.
- Reuse Anode's existing Screen Recording permission flow and status text style.
- The overlay must exclude itself from capture, hide the cursor in the capture, and match the display's scale
  and colour space so the swap from live screen to overlay is invisible.
- Settings follow the existing `Settings` pattern in `Sources/PowerKit/Settings.swift`.
- Sensor reads run off the main thread, on their own queue, and a hung read must never be retried in a way
  that stacks up blocked work.
- Testing happens without interrupting the owner: no lid closing, no full-screen overlays, during their
  working hours; headless checks and a harness that renders to files are fine.

## Author's calls (settled after a builder review; the owner can overrule any)

- **How much of the close is visible.** Not known without closing the lid on the owner's Mac, which was not
  done. The reference apps work on the same kind of hardware, so the display evidently stays lit for most of
  the close. The plan must include a measurement step: build, then record at what angle the display goes
  dark, and let that decide how the blur curve is spread over the visible range (the strongest blur must be
  reached before the display goes dark, not at 0°).
- **Capture at the trigger unless measured too slow.** Prewarm costs more CPU per close and, gated only by
  angle, could run all session at a normal working angle, so it is built only if measurement requires it,
  and then gated on downward motion. If it is built, the held picture may be about 0.2 s old and moving
  video may jump slightly at the swap; that is accepted.
- **Making the swap invisible.** Verify with a harness that compares a live capture against what the overlay
  draws at zero blur (pixel difference). If an exact match is not possible for some content (HDR, True Tone,
  Night Shift), cross-fade the overlay in over 2–3 frames instead of cutting. Perfect HDR fidelity is not a
  goal.
- **Read failures.** If reads run slow (over about 8 ms) or fail repeatedly during the active phase, drop the
  poll rate to 60 Hz; never queue a read behind a hung one. If the sensor stops responding or disappears
  (wake, re-enumeration), the feature switches itself off quietly and says so in its Settings section.
- **External displays and clamshell.** If any external display is attached, the closing effect does not run.
  A display-configuration change cancels any running effect.
- **Which unlock plays the opening effect.** Only the first unlock after a lid close that the closing effect
  saw (the notification is the distributed `com.apple.screenIsUnlocked`). Unlocks from the screen saver or a
  manual lock do not play it. Any key or mouse input cancels the clearing and removes the overlay.
- **macOS 13 and permissions.** On macOS 13 the section says it needs macOS 14 or later and the toggle is
  disabled. If Screen Recording is not allowed, show the existing status text and "Open Screen Recording
  Settings…" button, the same as Dock previews, and the effect stays off.

## Left to the builder

- The exact prewarm margin and default trigger angle (the author suggests a trigger around 110° and a default
  range of roughly 60–150°; neither was decided).
- Module layout, file names, setting key names.
- Spring tuning and the clearing animation's curve.
- Details of the shader after tuning.
- How to detect "this Mac has no sensor" cleanly.
- Whether to log feature activity in `FeatureLog.swift`, following existing features.
