# Hardware View: reference material for the build

- `mockup-source.html`: the approved interactive mockup (source, with `__PHOTO_B64__` where the photo is embedded). It is the visual
  blueprint; all positions, colours, copy and the layout data live in its `LAYOUTS` object and `DRAW` functions.
- `cpu-die-mockup-source.html`: the separate CPU/GPU die mockup (a later feature).
- `macbook-pro-teardown-straightened.jpg`: the stand-in photo, 1700 x 1165, already warped to a true rectangle.
  Source: "Teardown of MacBook Pro 16 inch laptop.jpg", Netha Hussain, Wikimedia Commons, CC0 (Intel-based 16-inch, 2019).
- `warp.json`: `H` (3x3 homography as 9 numbers) maps ORIGINAL photo pixels (the 3415 px wide original, `K` = 3415/2296 converts the
  2296-wide "display" coordinates used throughout the mockup) to straightened pixels; then `u' = u * RR / (RA + RB * v)` is the
  second pass that squares the leaning right wall. `WP()` in the mockup is the reference implementation.
- `pipe-symmetric.json`: the left-right symmetric heat-pipe path (in straightened pixels) and the centre line `uc`.

Licensing: the photo is CC0. Apple's own images, and iFixit's photos, are NOT used or embedded (all rights reserved).
