# Menu Bar Hider: results

Measured on the owner's 14" notched MacBook, macOS 27, screen 1800×1169. Probes: `docs/superpowers/spikes/2026-11-11-menu-bar-hider-ids-probe.swift`, `…-flatness-probe.swift` (the latter hung waiting for a Screen Recording prompt and was replaced by `screencapture -R`, see step 4). Everything below was read-only: no cursor movement, no window switching, nothing pressed.

## Task 9, step 1: what the bar looks like to Accessibility (read-only)

- 18 items. Four are parked at x −1…7, y 1157 (G HUB, 1Password, WireGuard, Synology Drive; OpenVPN was not running). Anode's own items: x 1067–1495 (eight widgets at the time).
- **The system's items all belong to `com.apple.MenuBarAgent`**, not Control Center. Each is an `AXHostingView` group with no actions of its own; the **first child** (`AXMenuExtra`) carries `AXIdentifier`: `com.apple.menuextra.focusmode`, `.wifi`, `.sound`, `.battery`, `.controlcenter`, `.clock`. Their `AXAttributedDescription` is the name ("Wi‑Fi, connected, 3 bars", "Sound", "Battery", "Control Center", "Clock").
- **Third-party items carry no identifier, no title and no description.** G HUB, 1Password, WireGuard and Synology Drive have an empty title and no description; they are told apart only by their order among their app's items (`bundle|#0`). They do have `AXPress`, and their first child is their `AXMenu` (reading it is passive).
- Anode's own items carry their name in the description ("Memory used", "CPU usage", …).
- Departure from the plan: the reader reads the identifier and description from the first child when the item is a hosting group, and presses the child when the group has no `AXPress`. The item key for the system's items is `com.apple.MenuBarAgent|com.apple.menuextra.<name>`, which the default arrangement (battery, sound, wifi) and the locked list (clock, controlcenter) already match.

## Task 9, step 4 (risk 3): is the bar a flat colour? (read-only)

Four captures of the top 8 pt of the bar over x 1060–1500, 20 s apart, with `screencapture -x -R1060,0,440,8`: every pixel black (luminance 0…0, brightest channel 0) in all four. The bar on this Mac is solid black, so a black cover is seamless. A non-black or translucent bar was **not** seen; the cover is black regardless and the Beta Features section will say a coloured bar may show a patch. (Colour sampling for such a bar was left out: nothing here can test it.)

## Not yet measured (need the owner's go-ahead)

- Risk 1: do the parked items return when Anode's widgets leave the bar? (step 2)
- Risk 2: where does `AXPress` open an item's menu, for an on-bar item and a parked one? (step 3)
