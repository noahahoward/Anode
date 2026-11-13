# Ultra Low Power Mode: results

Task 1 of `2026-11-12-ultra-low-power-mode.md`, on the owner's 14" MacBook Pro, on battery, 2026-11-12. The other session's builds were paused for these runs. Probes: `docs/superpowers/spikes/2026-11-12-ultra-low-power-*`.

## Step 1: is freezing safe? NO, not as specified. One class must not be frozen.

Run: 120 s as is, 300 s with 15 processes of six apps and tools stopped, 120 s as is. Whole-Mac power and per-process CPU every 10 s.

| Stretch | Whole Mac (median) | Processor rail (median) |
|---|---|---|
| Before | 3.39 W | 0.21 W |
| Frozen | 14.38 W | 10.69 W |
| After | 3.51 W | 0.30 W |

- **Cause:** one process, at 99% of a core on average and up to 200%, for the whole frozen stretch. It is a file-sync client's event daemon, which runs **as root** from a second copy of the app in `/Applications`, while the client's other processes run as the user from `~/Library/Application Support`. Anode stopped the user-level ones and could not stop the root one; with its partners silent, it spun.
- **Rule that replaces the spec's** (the plan's "if one class causes it, that class moves to never touched"): **a group with a member Anode cannot stop is not frozen at all.** A member is any process Anode cannot signal (another user's, root's) that belongs to the same product: its executable is inside the same bundle, or it carries the same signing team as a member of the group. Apple's own team does not count.
- **A second rule the run shows is needed:** a guard after every freeze. For the first seconds, and again at each sweep, look at per-process CPU; a process that was quiet and is now burning means something it depends on was stopped. Continue the group it belongs to (same bundle or team), remember that for the session, and say so in the menu. If no group can be tied to it, continue everything that was stopped in that step. The mode must never make the Mac draw more than before.
- No other process rose in the per-process readings, and every stopped process came back when continued. The owner used the editor through the frozen stretch and says it felt normal.
- **The owner's decision (2026-11-12):** an app with a part Anode cannot freeze is left running ("leave it running"), not frozen through the helper.
- **The rule can be computed without root** (read-only check): `sysctl(KERN_PROC_ALL)` lists every process (979, of which 350 are not the user's; `proc_pidinfo` reads only the user's own); `proc_pidpath` gave the path of 349 of those 350; and the signing team of a root process can be read with the Security framework. The sync client's root daemon and its user-level daemon carry the same team. Two other products on this Mac have a root process of the same team as a user-level one (a device-settings agent's updater, a VPN client's helpers), so they are left running too.
- Whole Mac at rest with the slider at 0.47 and nothing else running: **3.4 to 3.5 W**, which is the target (about 5% an hour) without the mode.

## Step 3: bringing a stopped app forward. GO.

A stopped throwaway app opened from the launcher: `NSWorkspace.didActivateApplicationNotification` arrived 0.55 s later, naming it, while it was still stopped. So "bringing a frozen app forward un-freezes it" can be built on that notification.

## Step 4: hide, then stop. GO, with a wait.

| Wait after `hide()` | Windows left after the stop | `isHidden` |
|---|---|---|
| 0 s | 1 | false |
| 0.2 s | 0 | true |
| 0.5 s | 0 | true |
| 1.0 s | 0 | true |

Stopped at once, the window stays on screen as a dead picture (it went away when the app was continued). Rule: after `hide()`, wait until `isHidden` is true, checking every 50 ms for up to 1 s, then stop either way.

## Step 7: how processes belong to apps (read-only)

- `responsibility_get_pid_responsible_for_pid` is there and reads without root. Only the user's own processes can be read at all (621 on this Mac), which is also the set Anode can signal.
- The editor is responsible for 76 processes, including the shells and command-line tools run from its terminal and ten in system locations. So "belongs to" by responsible process keeps a kept editor's tools.
- **Where "responsible" must not be trusted alone:** tools started from a terminal that detach are their own responsible process with parent 1 (a development server started with a package runner; its interpreter children are in turn their own). They form groups of their own ("background tools with no app"), named by executable. This is the case the owner chose to freeze by default; the confirm box names them.
- System helpers attributed to an app: one small store-update service per app, the open-and-save panel service, a credential helper. Freezing them with their app is consistent with "belongs to wins".
- launchd labels come from `launchctl list` (pid, label): apps as `application.<bundle id>…`, tools as their job label.
- **Event taps:** `CGGetEventTapList` lists 51. Four are enabled, all Anode's own. A device-settings agent holds 47, all **disabled**. Rule: only an **enabled, non-listen-only** tap makes its owner "never touched".
- **Audio:** the per-process audio objects (macOS 14 and later) report input and output running per pid; nothing was using either during the read. On macOS 13 there is no such list: the app is then only named in the confirm box.

## Step 8: keyboard backlight. GO.

`KeyboardBrightnessClient` in the private CoreBrightness framework reads and sets the level without root (`copyKeyboardBacklightIDs`, `brightnessForKeyboard:`, `setBrightness:forKeyboard:`). Set to 0, read back 0, restored to 0.372. Auto-brightness for the keyboard was on and did not fight the change within 2 s.

## Step 2: Low Power Mode and the floor. No saving at rest.

One administrator prompt set the battery power mode to 1 and back to 2. Slider at 0.47 throughout, Mac left alone.

| Stretch | Whole Mac (median) | Processor rail (median) |
|---|---|---|
| Before (password box on screen) | 4.14 W | 0.34 W |
| Low Power Mode alone, 90 s | 3.52 W | 0.21 W |
| Low Power Mode, lowest refresh rate, 12 processes stopped, 115 s | 3.73 W | 0.21 W |
| After: High Power, 120 Hz, nothing stopped, 45 s | 3.33 W | 0.19 W |

- On a Mac at rest, Low Power Mode, the lowest refresh rate and the freeze together read no lower than the Mac left as it was. The differences are inside the run-to-run spread of about 0.3 W.
- So the resting floor on this Mac is about 3.3 to 3.7 W at this brightness, whatever else is switched. Only brightness moves it (0.25 of the slider read 2.8 W in the first session).
- What Low Power Mode does under load (a build, a busy tab) was not measured. That, and stopping bursts, is where these parts can matter; the section's note must say so and must not claim a saving at rest.
- The sync client's group was left out of the stopped set, following Step 1.

## Step 5: sleep with a stopped app. GO.

A stopped throwaway app, the Mac put to sleep and woken 327 s later: the process was still there and still stopped, and came back with its window when continued. (Logout is still to be checked in the last task.)

## Step 6: holding the brightness ceiling. NOT TESTED.

The hold ran for 120 s and never had to act: the level stayed at 0.47, so no key press or sensor change arrived. To be repeated with the owner pressing brightness-up.

## State left behind

Power mode 2 (as before), brightness 0.468 (as before), 120 Hz, no process stopped, the throwaway app quit.
