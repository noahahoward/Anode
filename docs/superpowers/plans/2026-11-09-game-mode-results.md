# Game Mode HUD: what was measured (2026-11-09, MacBook with a notch, macOS 27)

Verified on this Mac with Bloons TD6 (Steam, native fullscreen, not a Cocoa fullscreen window).

## Works
- **Over a fullscreen game.** The strip sits in the black band above the picture, top-right, and covers none of the game. Screenshot confirmed: `CPU 46°C 10%   GPU 45°C 59%   RAM 73%   BAT 95% −21%/h`.
- **Numbers move.** Under eight busy loops the CPU figure went 10% → 35%; temperatures read real (CPU 45–54 °C, GPU 45–53 °C), battery drain changed from −23 to −21 %/h.
- **Goes away.** Switching to Brave hid it within 1.5 s (window off-screen; `gamemode.log` shows the hide).
- **Apple's Game Mode as the signal.** `com.apple.system.game_mode_status_changed` reads 1 with the game in front and 2 with Brave in front, ~0.4 s after the switch. In `gamemode.log` the category rule shows the strip at activation ("a game") and the notification then re-decides it as "Apple Game Mode". The Games-category rule and the added-apps list stay as the fallback.
- **Hot corner.** With the automatic option off and the hot corner on, the pointer touching the top-right corner shows the strip for 4 s: under the menu bar over a windowed app (Brave), in the black band over the fullscreen game.
- **Tests:** full suite 2058 run, 8 skipped (as before), 0 failures.

## Cost
Anode's own CPU with the strip up (game in front, 2 s ticks, sensors read): 0.46 s of CPU in 30 s, about 1.5% of one core. A feature-off baseline could not be measured cleanly (focus kept moving between Brave and the game, and Anode's own window had just relaunched), so the strip's added cost is not separated from noise. It is bounded: nothing runs with the feature off; with it on and no game in front the only thing alive is the workspace observer and a Darwin notification.

## What went differently from the plan
1. **A plain `NSWindow` never reached the game's Space.** From a regular-policy app it was ordered front yet reported off-screen. A non-activating `NSPanel` with `hidesOnDeactivate = false` does. (The first spike worked because that process was an accessory app.)
2. **Fullscreen cannot be read from the menu bar's window.** The window server's "Menubar" window stays listed on screen on a notched Mac even in fullscreen. The system-wide presentation options can: Bloons TD6 sets `hideMenuBar` + `hideDock` (raw 10); with a browser in front they are empty. At the instant of activation the options are not yet set, so the first decision is "not fullscreen" and the next tick (≤ 2 s) corrects the strip's position; the log shows this.
3. **A hidden window's tick never reaches `apply(_:)`.** The strip froze on its first reading until the refresh call moved after the visible/hidden branch.
4. `safeAreaInsets.top` is 38 here while the game's black band is 39 pt; the strip is centred on 38 (half a point).
5. The app's settings live in the `com.anode.settings` defaults domain, not `dev.anode.app`; an external `defaults write` is not noticed until Anode relaunches.

## Not verified on hardware
- Bottom corners and the top-left corner (the geometry is unit-tested for all four on two screens).
- A second display.
- Clicking through the strip itself (`ignoresMouseEvents` is pinned in a test; the 6 pt hot-spot panel does catch the pointer by design).
- A game that locks or hides the pointer: the hot corner cannot fire there.
- FPS: not attempted (separate spike).
