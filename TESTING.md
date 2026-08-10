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

## Fan control: off by default, and nothing is installed unless you ask

Fan control is off until you turn it on, and turning it on does not install
anything. There is no launch daemon, no plist, and no root process on your
machine unless you have deliberately started one — or pressed **Install Fan
Helper…**, which is the one thing in this app that leaves something behind.

There are two ways to run the privileged half. The session helper below is the
default and the stronger of the two. The install is described further down,
together with what it costs.

To use the session helper, open the Fans tab, click **Turn On Fan Control…**, and
run the command it shows you in Terminal:

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

### Installing it instead, and what that costs

Typing a `sudo` line every session is fine while you are working on BetterStats
and tiresome otherwise, so there is an **Install Fan Helper…** button. It asks
for your password once and then fan control works with no prompt of any kind —
after a rebuild, after a reboot, forever, until you uninstall.

It installs exactly two files, both owned by root and neither of them writable by
you:

```
/Library/PrivilegedHelperTools/dev.noah.betterstats.fanhelper
/Library/LaunchDaemons/dev.noah.betterstats.fanhelper.plist
```

The equivalent by hand, if you would rather read it than click it, is the same
command the button runs:

```sh
sudo ~/Applications/BetterStats.app/Contents/MacOS/BetterStatsHelper --install
```

It works without an Apple Developer ID because launchd does not check signatures
for plists placed in `/Library/LaunchDaemons` — Apple's own SMAppService header
says so, and says the filesystem permission on `/Library` is the check. The
modern API (`SMAppService.daemon`) is closed to us: the same header says apps
containing LaunchDaemons must be notarised.

**Nothing is resident.** Installing does not put a root process on your machine.
The job has no `RunAtLoad` and no `KeepAlive`; it declares a `Sockets` entry, so
launchd holds `/var/run/betterstats-fan.sock` itself and starts the helper only
when something connects. The helper exits again after 90 seconds with no client
and no fan held. So: nothing at boot, nothing while BetterStats is closed,
nothing while fan control is off.

The socket launchd creates has the same owner and mode the session helper sets
for itself — `SockPathOwner` is the installing uid and `SockPathMode` is 384,
which is 0600 in the decimal that property lists force. On-demand launching moved
*who creates the socket*, not who is allowed to talk to it; `getpeereid` still
does the real enforcement on every connection.

Two rules keep that safe, and both are tested against a real socket rather than
argued for. A helper never unlinks a socket it did not create, because launchd is
still holding that path and it is how the *next* helper gets started. And a
helper still holding fans it could not release never idle-exits, because leaving
would drop the only record of where those fans belong.

An idle helper costs nothing measurable either way: it blocks in `poll()` with no
timeout, no threads and no timers, so it is not scheduled at all between
requests.

**What you give up, plainly.** The session helper trusts exactly one build,
because it pins the app's code hash when it starts. The installed daemon cannot
do that — it outlives your rebuilds, and a hash pinned at install time would be
stale after the next `./build-app.sh`, which would turn the button into
"reinstall after every build". So it pins the *signing identifier* instead, and
anybody can claim that identifier with one command:

```sh
codesign --force --sign - -i dev.noah.betterstats some-other-binary
```

So after you install, **anything running as your user can set your fan speeds**,
within the range the fan itself reports, until you uninstall. Another user on the
Mac still cannot — that check is the kernel's and does not weaken — and nothing
at all can before you install. There is no version of this that is airtight
without a Developer ID, because an ad-hoc signature has no key an attacker cannot
also use.

What is left is a real but small boundary: the daemon's entire vocabulary is "set
fan N to R rpm" and "release", every speed is re-clamped against limits read
fresh from the fan, and there is no path or key name anywhere in its input.

**Uninstall** removes both files, unloads the daemon, deletes the socket and
hands the fans back to automatic. It is the **Uninstall Fan Helper…** button, or
the same `--uninstall` command above.

The full trust model, including what it does *not* protect against, is at the top
of `Sources/PowerKit/FanLink.swift`.

## The Fans tab is missing on some Macs

That is deliberate: a machine whose SMC reports zero fans (a MacBook Air, a
fanless desktop) does not get the tab, and ⌘1…⌘4 renumber behind it. A machine
whose SMC could not be read *keeps* the tab — "not measured" is not "none", and
the pane says which of the two it is looking at.
