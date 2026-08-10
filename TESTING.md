# Giving BetterStats to someone else

Written for the first person other than the author to run this. It says what to
expect, what will be wrong on their machine, and what to send back.

## Install by building, not by receiving a binary

```
git clone <this repo>
cd better-stats-app
./build-app.sh                    # installs to ~/Applications/BetterStats.app
open ~/Applications/BetterStats.app
```

**Do not send a built `.app`.** Not out of caution theatre — the reason is
specific. This app is ad-hoc signed and not notarised, so a bundle that arrives
over the internet is quarantined and will not open. The usual workaround is
`xattr -dr com.apple.quarantine`, and telling someone to run that means telling
them to disable the one check standing between "a binary a friend sent me" and
"a binary running with my full user privileges" — on an app that is deliberately
**unsandboxed** and enumerates every process on the machine.

A locally built bundle is never quarantined, so building from source removes the
problem instead of teaching someone to disable the protection. It needs Xcode,
which is the cost.

There is also **no update mechanism**. Whatever is shipped is permanent until
manually replaced, which is a second reason to hand over a repo rather than a
binary: `git pull && ./build-app.sh` is the update mechanism.

## What will be wrong on a Mac that is not Mac17,9

Most of this app is machine-independent: `proc_pid_rusage` energy, the battery
gas gauge, coalition rollups, the conservation invariant. Some of it is not, and
those parts **switch themselves off** rather than produce a confident wrong
number:

| Calibrated on Mac17,9 | Elsewhere |
|---|---|
| Backlight response curve (span 8.19 W, dead zone 0.20, exponent 1.75) | No display segment from the curve. The `PDBR` rail is still used if present — it is a sensor, not a fit. |
| Memory rails `P3F2`+`PZD1`, storage rail `PN00` | No memory or storage segment. Those watts stay in the unattributed bucket. |
| CPU rail→battery factor 1.27 | 1.0, i.e. no correction applied. Not a claim the factor is 1.0 there. |

So on other hardware the ledger is **smaller but still true**: fewer named rows,
a larger honest "unidentified" remainder. That is the intended behaviour. A
ledger row that is decorated rather than measured is the exact failure this
project exists to avoid.

Expect the unattributed share to be noticeably larger than on the author's
machine. That is not a bug report — it is the gate working.

## What is genuinely worth reporting

Ranked by how much they would tell us:

1. **The menu bar and the window disagreeing** about the same quantity. They
   read one published value, so any difference between them is a bug.

   **Known exception, do not report:** the charge percentage and the time
   remaining do NOT divide into each other, and are not meant to. The percentage
   shown is the gauge's own integer `CurrentCapacity`, so that it matches what
   macOS shows; the time is computed from `RemainingCapacity/FullChargeCapacity`,
   which reads about 4% lower and which the gauge's own time-to-empty agrees
   with. Observed: 53% at 15 %/hr showing 3h 23m, where 53/15 would be 3h 32m.
   The time is the accurate one. Reporting a gap larger than ~6% IS worth doing.
2. **A ledger that does not conserve.** The bar prints an overflow warning if the
   rows exceed the measured total. If that warning ever appears, say so.
3. **Anything after sleep.** Close the lid, leave it, open it. Drain, time
   remaining and the graph must not show a reading of the sleep.
4. **Cost of the app itself.** Idle should sit near 0.2% of one core with the
   window closed. If it is materially higher, that matters more than any feature.
5. **A crash.** `~/Library/Logs/DiagnosticReports/BetterStats*`.

Less useful: absolute agreement with Activity Monitor. Rank correlation is
expected, value agreement is not — Energy Impact is unitless and this is joules.
Divergence is the point of the project, not evidence against it.

## What it reads

Worth being able to answer honestly, since it is unsandboxed:

- Per-process CPU and energy counters for processes owned by the same user.
- Names and bundle identifiers of running processes, so rows can be labelled.
- Whole-system power and battery state from SMC and IORegistry.
- `systemstats` coalition rollups, which macOS already keeps in world-readable
  files under `/var/db/systemstats`.
- Attached USB device names, to attribute charging draw.

It writes one SQLite file, `~/Library/Application Support/BetterStats/history.sqlite`.

**Network egress: exactly one thing, and only when you ask for it.** The speed
test contacts `speed.cloudflare.com` and both downloads and uploads real data
(up to 25 MB down, 10 MB up). It runs on explicit request only — never on a
timer, never at launch, never as a side effect of opening a pane. Nothing else
in the app or the CLI sends anything anywhere: there is no telemetry, no crash
reporting, no update check, and no analytics.

If you never run the speed test, the app makes no network connections at all.

## Fan control: off by default, and nothing is installed

Fan control is off until you turn it on, and turning it on does not install
anything. There is no launch daemon, no plist, and no root process on your
machine unless you have deliberately started one and left it running.

To use it, open the Fans tab, click **Turn On Fan Control…**, and run the command
it shows you in Terminal:

```sh
sudo ~/Applications/BetterStats.app/Contents/MacOS/BetterStatsHelper
```

It prints what it will accept and then waits. The app picks it up within a few
seconds and the sliders come alive. Press ⌃C to stop it; the fans go back to
automatic control when you do, and also if BetterStats quits or crashes — the
helper hands them back the moment its client disappears.

While it runs, exactly one program can set a fan speed: that build of
BetterStats, run by you, within the minimum and maximum the fan itself reports.
Another user cannot reach it (the socket is 0600 in a root-owned directory) and
another program of yours cannot either (its cdhash will not match).

**Rebuilding invalidates it, by design.** The helper pins the app's code hash
when it starts, and an ad-hoc signature changes on every build, so a helper left
running from before a rebuild will refuse the new app and say so. Stop it and
start it again if you still want fan control. This is not a repair — it is the
privileged session ending, and declining to start another one leaves you with
exactly the monitor you had before.

There is one gap and it is worth knowing: if the helper is killed with `kill -9`
nothing runs, so a fan left at a manual speed stays there. The way out is:

```sh
sudo ~/Applications/BetterStats.app/Contents/MacOS/BetterStatsHelper --uninstall
```

which hands every fan back unconditionally and removes everything this project
has ever asked root to leave on the disk — including the launch daemon, helper
binary and pinned-hash file that an earlier draft of this feature installed.

The full trust model, including what it does *not* protect against, is at the top
of `Sources/PowerKit/FanLink.swift`.

## The Fans tab is missing on some Macs

That is deliberate: a machine whose SMC reports zero fans (a MacBook Air, a
fanless desktop) does not get the tab, and ⌘1…⌘4 renumber behind it. A machine
whose SMC could not be read *keeps* the tab — "not measured" is not "none", and
the pane says which of the two it is looking at.
