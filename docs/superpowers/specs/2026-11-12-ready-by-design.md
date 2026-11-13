# Ready By — design

Date: 2026-11-12. Part of Charge Control (Beta Features). Decided with the owner; items marked **(my call)** were
chosen by the designer and are the owner's to overrule.

## What it is for

The owner plugs the Mac in and wants the battery at the charge limit **by a time of day** ("time to finish, not time
to start"). Until charging has to begin, the battery should rest where it is rather than sit at the limit for hours.
The usual case is overnight: plugged in in the evening, lid closed, ready at 7:00.

## Behaviour

- One switch, **Ready By**, and one time of day. The time applies every day (owner's decision).
- While the Mac is on the charger, below the limit, and the next Ready By time is **no more than 12 hours away
  (my call)**, Charge Control holds the battery at its current level. If the next time is further away than that, Ready
  By does nothing and the battery charges to the limit as usual: a Mac plugged in at 8:00 with a 7:00 time must not sit
  at 30% all day.
- It never holds below **30% (my call)**: below that it charges to 30% first, then holds.
- It starts charging at `time − (time needed) − 15 minutes`, where the time needed comes from the charge rate measured
  on this Mac (below). Once started it does not stop again for that time (no flapping when the estimate moves).
- If there is not enough time, it charges at once.
- After the time has passed, the limit behaves as usual until the next window.
- Unplugging ends the hold. It never drains the battery to wait.
- **Charge to Full** overrides it. **Pause When Hot** still pauses (a hot pack matters more than the time).
  **Hold Level During Sleep** yields to it inside the window: Ready By's own hold is the same thing before the start,
  and after the start the battery must charge while the Mac sleeps.
- It needs the Anode helper: holding at an arbitrary level and waking the Mac both need it. Without the helper the
  section says so and offers Install Helper…, as the other holds do.
- The limit is in force only while Anode runs (existing rule): quitting puts macOS's own settings back, so a quit
  during a hold lets the battery charge.

## Asleep

Anode cannot run while the Mac sleeps. Measured on Mac17,9, macOS 27.0, lid closed, on the charger (2026-11-12):

- A limit written at the current level (54 at 54%) held through sleep: "AC attached; not charging".
- A wake scheduled with `pmset schedule wake` fired on the second. A root process ran at that wake and wrote the limit
  80; macOS had it in force within a second.
- Charging then continued with the Mac asleep again: 54% → 60% in about four and a half minutes.

So: when the Mac is about to sleep during a hold, the app tells the helper the level to raise to and when (the send
is waited for, like the sleep hold). The helper schedules a wake for that moment and stays alive. It writes the limit
when the moment has come, whichever tells it first: the system-wake notice it already listens for, or its own
wall-clock timer; then it removes its scheduled wake. Before writing it checks that a charger is there; without one it
writes nothing and drops the plan.

The plan survives wakes that are not the person's. A Mac asleep on the charger wakes by itself many times a night, and
whether the app is told "about to sleep" again after each of those has not been measured. So the app does not cancel
the plan merely because the Mac woke: on any wake it looks again, and if the moment has come it raises the limit itself
and cancels; if not, it leaves the plan where it is (sending the same plan again before the next sleep replaces it,
which is harmless). The app cancels the plan when the hold ends for a real reason: unplugged, Ready By or Charge
Control switched off, the time or the limit changed, Charge to Full pressed, or Anode quitting. The plan also lives on
the helper connection, like a drain: if the connection closes, the helper cancels the scheduled wake and writes
nothing.

Not measured, to be measured on hardware before release: the lid open and the Mac asleep (the scheduled wake was a
full wake; the display may light, and the Mac returns to sleep on its own idle timer); the charger pulled while asleep
(the helper must check the charger at the wake and do nothing without one).

## Charge rate

- Learned, per charger class (the adapter's rated power in three bands: under 30, 30 to 65, over 65; never shown to
  the person). Measured only while charging between 20% and 80%, over spans of at least five minutes, as percent per
  minute, kept as a running average and stored.
- Until one is learned for a band: 0.3, 0.8 and 1.0 percent per minute (slow guesses, so an unknown charger starts
  early rather than late). Measured once so far: about 1.3 percent per minute at 54–60% on a 100 W charger.
- Above 80% charging tapers: that part of the way is counted at half the rate.
- Clamped to 0.1…3 percent per minute; a nonsense reading never becomes the estimate.

## Parts

1. `ChargePolicy` (pure): new settings (`readyByEnabled`, `readyByMinutes` after local midnight), new inputs (the next
   Ready By moment, the rate), a new reason and status, and in the decision the moment to raise at. Rule order:
   unplugged; Charge to Full; Pause When Hot; **Ready By hold**; Hold Level During Sleep; draining; drift; the limit.
2. `ChargeRate` (pure + a small store): the learner above.
3. `ChargeController`: computes the next moment (calendar-correct across time zone and daylight-saving changes),
   feeds the policy, schedules a tick for the start moment while awake, sends the plan to the helper before sleep
   (waited, like the sleep hold), cancels it on wake, on unplug, on switching off, on quit.
4. Helper: two commands (`scheduleChargeLimit(limit, at)`, `cancelScheduledChargeLimit`), protocol version 3, the
   wake scheduled and cancelled through an injectable power-event interface, the plan dropped when the client
   disconnects, the disclosure texts naming the new ability (it wakes the Mac at a time Anode gives it).
5. Section: the switch, a time picker, and a status line in plain words ("Holding at 54% until 5:40 am, then charging
   to reach 80% by 7:00 am"; "Charging to reach 80% by 7:00 am").
6. Main card: its "charging to" and "held at" lines follow the hold.

## Tests

The policy matrix (window, floor, start moment, no flapping, each override); the rate learner; the controller across
sleep and wake with a fake helper and clock; the helper with a fake power-event scheduler (schedule, fire early wake,
cancel, client gone, charger gone); the strings. On hardware: one overnight charge, lid closed; lid open asleep;
charger pulled while asleep; quit during a hold.
