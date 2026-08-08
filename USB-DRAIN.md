# USB device charging — measured

## The finding

Charging an iPhone from the laptop costs **11.55 W**, measured directly.

    nothing attached    PSTR 10.04 W    PPBR 10.07 W
    iPhone attached     PSTR 21.59 W    PPBR 21.61 W
                        delta +11.55 W  +11.55 W

On a ~72 Wh pack that is **16 %/hr**, or roughly 1.5 hours of laptop runtime to
charge a phone that has its own charger.

CPU and GPU went DOWN by 1.09 W across the same transition, so 12.6 W of the
step is unexplained by any compute rail. The step is clean, repeatable, and
appears within one sample of plugging in.

This is why a drain reading of ~24 %/hr looked impossible to the user while
being correct: 14-16 of those points were going into a phone.

## It is not separately metered

No SMC rail carries it. Every rail was compared across the transition; the
largest port-family mover was `PP0b` at +0.90 W, 8% of the draw. The power
appears only in the totals — `PSTR`, `PPBR` and `Pb0f` all step together by
~11.5 W.

So USB cannot become a measured ledger segment the way memory and storage did.
There is no rail to read.

## What the app can honestly do

Detect that devices are attached and say so, without claiming a wattage it
cannot measure. `IOUSB` enumeration is unprivileged and gives the device names
("iPhone", "MagSafe Charging Case (USB-C)").

That is worth surfacing on its own: the user's complaint was not that the number
was wrong, it was that it was unexplainable. "2 USB devices attached, and their
charging is included in unattributed" resolves that completely, and it is a
claim the app can actually support.

Attributing watts per device would require observing the step change at
attach/detach time — real, but it only works for devices connected while the app
is running, and never for one already attached at launch. Worth building later;
not worth faking now.

## Why this matters beyond the number

No process is responsible for this power, so it appears nowhere in Activity
Monitor, in `top`, or in any per-app view in any tool. It is invisible to the
entire category of software people reach for when a laptop drains fast.

Measuring whole-system draw and printing the unattributable remainder — rather
than dividing a total among apps — is what made it findable at all.
