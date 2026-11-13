# Ultra Low Power Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One manual switch that freezes every app and background tool the owner is not using, holds the screen dim and slow, turns on macOS Low Power Mode and pauses Anode's own measuring, and puts all of it back when switched off or when Anode goes away.

**Architecture:** The decisions (which process is in which pile, what to restore, when to tick) are pure functions in `PowerKit`. Everything that touches the Mac (process list, signals, hiding, brightness, refresh rate, keyboard backlight, power mode, the watchdog) sits in `AnodeApp` behind a protocol with a fake, so `UltraLowPowerController` is tested without sending one real signal. A record on disk, written before anything is stopped, is what a watchdog process and the next launch use to undo a session Anode did not end itself.

**Tech Stack:** Swift 5.9, SwiftPM (`PowerKit`, `AnodeApp`, `AnodeHelper`), AppKit, libproc, CoreGraphics display configuration, XCTest (`Tests/PowerKitTests`, `@testable import AnodeApp`).

**Spec:** `docs/superpowers/specs/2026-11-12-ultra-low-power-mode-design.md`

## Global Constraints

- macOS 13 deployment target; no new dependencies; a Beta Features section, unticked by default.
- **Base:** every code task is built on the 1.17.0 history, and only after the session building the charge feature says it is final. Until then only Task 1 may run. Before Task 2: rebase `ultra-low-power` onto that `main`. Never commit on `main`; never push without the owner's word.
- No other product's name, and no feature name coined by another product, in code, interface text, tests, commit messages or documents. Test fixtures use made-up ids (`com.example.editor`).
- No tester's name, or words like "friend", in a commit, comment or test.
- Tests never send a signal to a real process, change the real brightness, refresh rate, keyboard backlight or power mode, hide a real app, start a real watchdog, or read or write the real settings store or the real record file. Each has a fake; `Settings(defaults:)` gets a throwaway suite.
- Every call into another process or the system that can block runs off the main thread with a timeout.
- A frozen process is never killed. Only what the record names is ever continued, and only what this feature changed is ever put back.
- Brightness ceiling `0.5` of the slider. Refresh rate: the lowest the built-in display offers at the current resolution; external displays untouched.
- One root helper: the power-mode command is added to the existing one (Task 12), nowhere else.
- Each task ends with `./test.sh --quick` green. Subagents run on the smaller model, one implementer and one reviewer per task.
- Release (Task 13) follows `CLAUDE.md`: version, `CHANGELOG.md`, `UPDATE-NOTE.md`, tag; `ReleaseFilesTests` must pass.

## Review Focus

1. **A process id reused between the snapshot and the signal** (the app quit, another process got its id): nothing is signalled. → Task 6, `testARecycledPidIsNeverSignalled`.
2. **A kept app starts a new helper after the mode began**: the sweep never freezes it. → Task 3, `testANewProcessOfAKeptAppIsNotAnAddition`.
3. **Anode is killed while the mode is on**: recovery continues exactly what the record names and restores exactly what the record says was changed. → Task 4, `testRecoveryContinuesOnlyWhatTheRecordNames`.
4. **The owner dims below half during the session, then turns the mode off**: the earlier, brighter level is not put back. → Task 5, `testBrightnessIsNotRaisedBackWhenTheOwnerWentDimmer`.
5. **The process list cannot be read, or comes back partial**: the mode does not start. → Task 8, `testAFailedSnapshotStartsNothing`.

---

### Task 1: Measured gate (owner at a quiet Mac; no product code)

**Files:**
- Create: `docs/superpowers/spikes/2026-11-12-ultra-low-power-*.swift|.sh` (throwaway probes; the brightness, refresh-rate and run scripts from the first session are already there)
- Create: `docs/superpowers/plans/2026-11-12-ultra-low-power-mode-results.md`

**Interfaces:**
- Produces: the results file, with one line per risk saying GO, or the narrower rule that replaces the spec's. Tasks 3, 6, 7, 8 and 10 read it.

Before starting: message the other session to pause its builds, and tell the owner a password box will appear. Everything is restored on every exit path of every probe.

- [ ] **Step 1: Freezing on a quiet Mac (spec risk 1).** Freeze the spike set for 5 minutes while the owner uses the kept app (type, save, paste, build). Record whole-Mac power (`.build/release/anode --raillog`) and per-process CPU (`top -l` every 10 s) for the frozen stretch and for 2 minutes either side. Expected: whole-Mac power not above the stretches either side; no kept process above its unfrozen level. A class that spins or hangs goes to "never touched" in Task 3; if nothing safe remains, stop and report.
- [ ] **Step 2: Low Power Mode and the floor (risk 2).** One administrator prompt: `pmset -b powermode 1`, 90 s alone, then with brightness 0.5, lowest rate and the freeze for 120 s, then `pmset -b powermode 2`. Record each median. Expected: numbers for the section's note; no number stops the build.
- [ ] **Step 3: Bringing a stopped app forward (risk 3).** Stop one throwaway app (a blank text document), click its Dock icon, and log whether `NSWorkspace.didActivateApplicationNotification` names it. Record yes or no.
- [ ] **Step 4: Hide, then stop (risk 4).** Hide the throwaway app and stop it after 0, 0.2, 0.5 and 1.0 s; record the shortest delay after which no window is left on screen (`CGWindowListCopyWindowInfo`).
- [ ] **Step 5: Sleep with stopped apps (risk 5, first half).** With the throwaway app stopped, sleep the Mac for 30 s, wake, continue it. Expected: it comes back. (Logout is checked in Task 13, when the owner chooses.)
- [ ] **Step 6: The ceiling against auto-brightness and the keys (risk 6).** Hold 0.5 by setting it back whenever a read shows more, for 2 minutes, while the owner presses brightness-up and covers the light sensor. Record whether it flickers; if it does, the rule becomes "set once at start and after each key press".
- [ ] **Step 7: Read-only facts for the planner.** Dump, for every process of the user: pid, parent, responsible pid (`responsibility_get_pid_responsible_for_pid`, looked up with `dlsym`), path, app kind, launchd label; the owners of active event taps (`CGGetEventTapList`); and which processes hold audio input. Check by eye that a browser's page processes resolve to the browser, terminal tools to the editor, and that no system service used by several apps resolves to one app. Record every class where "responsible" is wrong.
- [ ] **Step 8: Keyboard backlight.** Find whether the level can be read and set without root; record the call or "no clean way".
- [ ] **Step 9: Commit** the probes and the results file: `git commit -m "Ultra low power mode: measured gate"`.

---

### Task 2: Settings

**Files:**
- Modify: `Sources/PowerKit/Settings.swift` (keys, defaults, accessors, in the pattern of `menuBarHiderEnabled`)
- Test: `Tests/PowerKitTests/UltraLowPowerSettingsTests.swift`

**Interfaces:**
- Produces: `Settings.Key.ultraLowPowerEnabled`, `Settings.Key.ultraLowPowerAlwaysKeep`; `var ultraLowPowerEnabled: Bool` (default `false`); `var ultraLowPowerAlwaysKeep: [String]` (group ids, default `[]`, stored as a JSON string; garbage reads as `[]`).

- [ ] **Step 1: Write the failing tests**

```swift
func testDefaultsAreOffAndEmpty()                 // false, []
func testAlwaysKeepRoundTrips()                   // ["com.example.vpn", "job:homebrew.db"] survives a new Settings on the same suite
func testGarbageInTheKeepListReadsAsEmpty()       // defaults.set("not json", forKey: "anode.ultraLowPowerAlwaysKeep") → []
func testObserversFireForEachKey()
```

- [ ] **Step 2: Run** `swift test --filter UltraLowPowerSettingsTests`. Expected: FAIL, no member `ultraLowPowerEnabled`.
- [ ] **Step 3: Implement** the two keys, defaults and accessors.
- [ ] **Step 4: Run** the same filter. Expected: PASS, 4 tests.
- [ ] **Step 5: Commit** `git commit -m "Ultra low power mode: settings"`.

---

### Task 3: The three piles (pure)

**Files:**
- Create: `Sources/PowerKit/UltraProcess.swift`, `Sources/PowerKit/FreezePlanner.swift`
- Test: `Tests/PowerKitTests/FreezePlannerTests.swift`

**Interfaces:**
- Consumes: the results file of Task 1 (classes moved to "never touched", classes where "responsible" is not trusted).
- Produces:

```swift
public enum AppKind: Equatable { case regular, accessory, none }
public struct UltraProcess: Equatable {
    public var pid: pid_t, parent: pid_t, uid: uid_t
    public var startTime: UInt64            // with pid, the identity of a process
    public var path: String                 // "" when unreadable
    public var responsible: pid_t?          // nil when unknown or itself
    public var app: AppKind
    public var bundleID: String?
    public var name: String                 // app name, else executable name
    public var launchdLabel: String?
    public var ownsEventTap: Bool, usesMicOrCamera: Bool
}
public struct FreezeGroup: Equatable { public var id: String; public var name: String; public var members: [Member]
    public struct Member: Equatable { public var pid: pid_t; public var startTime: UInt64 } }
public struct FreezePlan: Equatable { public var kept: [FreezeGroup]; public var frozen: [FreezeGroup] }
public enum FreezePlanner {
    public static func plan(processes: [UltraProcess], user: uid_t, front: pid_t?, alwaysKeep: Set<String>,
                            ownPIDs: Set<pid_t>) -> FreezePlan
    /// New members of groups already frozen, for the sweep. Released groups and kept groups never gain members.
    public static func additions(processes: [UltraProcess], user: uid_t, frozenGroups: Set<String>,
                                 known: Set<pid_t>, ownPIDs: Set<pid_t>) -> [FreezeGroup]
    public static func isSystem(_ p: UltraProcess) -> Bool
}
```

Rules, in this order (the spec's "What the mode does", section 1):
1. **Owner of a process:** its `responsible` process if set; else the nearest ancestor that is an app, or whose parent is pid 1; a process whose path lies inside an app's bundle belongs to that app. The group id is the owner's `bundleID`, else `"job:" + launchdLabel`, else `"exe:" + executable name`. Frozen group names are the owner's `name`.
2. **Never touched:** `uid != user`; `ownPIDs`; `isSystem` owners; a group in which any process `ownsEventTap`; any process whose path contains `.appex/` (left running even when its group is frozen).
3. `isSystem`: `app == .none` and path under `/System/`, `/usr/`, `/bin/`, `/sbin/` or `/Library/Apple/`; or `app == .accessory` with a `com.apple.` bundle id; or bundle id `com.apple.finder`, `com.apple.dock`, `com.apple.loginwindow`. A `.regular` app with a `com.apple.` id is not system.
4. **"Belongs to" wins over the path:** a system-located process whose owner is a freezable app is in that app's group.
5. **Kept:** the group of `front`; groups whose id is in `alwaysKeep`; a group in which any process `usesMicOrCamera`.
6. **Frozen:** every other group of the user's. `kept` in the plan lists only the three kinds in rule 5 (it is what the confirm box names).

- [ ] **Step 1: Write the failing tests** (fixture: a helper `proc(pid, parent:, path:, app:, bundle:, responsible:, …)` with `uid: 501`, `startTime: UInt64(pid) * 10`)

```swift
func testTheFrontAppAndItsTerminalToolsAreKept()        // editor 10; shell 11 (parent 10), tool 12 (parent 11) → not in frozen
func testAnotherAppIsFrozenWholeWithItsHelpers()         // browser 20, helpers 21, 22 inside its bundle → one group, 3 members
func testASystemLocatedHelperBelongsToTheAppResponsibleForIt() // path /System/…/XPCServices/…, responsible 20 → in browser's group
func testAppleAppsTheOwnerOpenedAreFrozen()              // .regular, com.apple.mail → frozen
func testSystemServicesAreNeverFrozen()                  // /usr/libexec/x, .accessory com.apple.controlcenter, com.apple.finder
func testOtherUsersProcessesAreNeverFrozen()             // uid 0
func testAnodeAndItsHelpersAreNeverFrozen()              // ownPIDs
func testAnEventTapOwnerKeepsItsWholeGroupRunning()
func testAnAppUsingTheMicrophoneIsKeptAndListedAsKept()
func testAlwaysKeepTakesAppsAndBackgroundTools()         // "com.example.vpn", "job:homebrew.db"
func testABackgroundToolWithNoAppIsFrozenUnderItsJobName() // parent 1, label "homebrew.db" → id "job:homebrew.db"
func testAToolWithNoLabelIsGroupedByExecutableName()     // id "exe:devserver"
func testExtensionsOfAFrozenAppAreLeftRunning()          // path …/Some.appex/… not a member
func testNoFrontAppStillPlans()                          // front nil
func testANewProcessOfAFrozenGroupIsAnAddition()
func testANewProcessOfAKeptAppIsNotAnAddition()
func testANewAppIsNotAnAddition()                        // launched later: left alone
func testKnownPidsAreNotAdditions()
```

- [ ] **Step 2: Run** `swift test --filter FreezePlannerTests`. Expected: FAIL, no type `FreezePlanner`.
- [ ] **Step 3: Implement** the two files. Apply any narrowing the results file of Task 1 calls for, with a test for each.
- [ ] **Step 4: Run** the filter. Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Ultra low power mode: which process is in which pile"`.

---

### Task 4: The record, and undoing a session Anode did not end (pure)

**Files:**
- Create: `Sources/PowerKit/UltraRecord.swift`
- Test: `Tests/PowerKitTests/UltraRecordTests.swift`

**Interfaces:**
- Consumes: `FreezeGroup` (Task 3).
- Produces:

```swift
public struct UltraRecord: Codable, Equatable {
    public var groups: [Group]                     // every group frozen this session, released or not
    public struct Group: Codable, Equatable { public var id, name: String; public var members: [Member]
        public var appPID: Int32?                  // the app that was hidden before it was stopped; nil = nothing was hidden
        public var released: Bool }
    public struct Member: Codable, Equatable { public var pid: Int32; public var startTime: UInt64 }
    public var brightnessBefore: Float?            // nil = the mode did not lower it
    public var rateLowered: Bool
    public var keyboardBefore: Float?
    public var powerModeBefore: Int?               // nil = not changed by this feature
    public init()
}
public protocol UltraRecordStoring: AnyObject { func load() -> UltraRecord?; func save(_ record: UltraRecord); func clear() }
public final class UltraRecordFile: UltraRecordStoring { public init(url: URL) }   // atomic write; unreadable or garbage → nil
public enum UltraRecovery {
    public enum Action: Equatable { case resume(pid: Int32, startTime: UInt64), unhide(pid: Int32),
                                    brightness(Float), restoreRate, keyboard(Float), powerMode(Int) }
    /// What undoes `record`, in order: processes first.
    public static func actions(for record: UltraRecord, brightnessNow: Float?) -> [Action]
}
```

- [ ] **Step 1: Write the failing tests**

```swift
func testRecordRoundTripsThroughAFile()                 // temp directory; never the real path
func testGarbageFileLoadsAsNoRecord()
func testRecoveryContinuesOnlyWhatTheRecordNames()      // 2 groups, one released → resume only the other's members, then unhide its appPID
func testProcessesComeBeforeSettings()                  // first actions are all .resume
func testNothingChangedMeansNothingRestored()           // brightnessBefore nil, rateLowered false, powerModeBefore nil → only resumes
func testBrightnessIsRestoredThroughTheCeilingRule()    // before 0.8, now 0.5 → .brightness(0.8); now 0.3 → no brightness action
```

- [ ] **Step 2: Run** `swift test --filter UltraRecordTests`. Expected: FAIL, no type `UltraRecord`.
- [ ] **Step 3: Implement.** `actions` uses `BrightnessCeiling.restore` from Task 5 once it exists; until then inline the same rule and switch over in Task 5.
- [ ] **Step 4: Run** the filter. Expected: PASS, 6 tests.
- [ ] **Step 5: Commit** `git commit -m "Ultra low power mode: the session record and how it is undone"`.

---

### Task 5: Screen rules and the tick rule (pure)

**Files:**
- Create: `Sources/PowerKit/UltraScreen.swift`
- Modify: `Sources/PowerKit/UltraRecord.swift` (use `BrightnessCeiling.restore`)
- Test: `Tests/PowerKitTests/UltraScreenTests.swift`

**Interfaces:**
- Produces:

```swift
public enum BrightnessCeiling {
    public static let ceiling: Float = 0.5
    public static let slack: Float = 0.01
    public static func clamp(_ current: Float) -> Float?                 // 0.5 when current > 0.51, else nil
    public static func restore(before: Float?, now: Float?) -> Float?   // `before` only when it was lowered and now is within slack of the ceiling
}
public struct DisplayModeInfo: Equatable { public var index: Int; public var width, height, pixelWidth, pixelHeight: Int; public var rate: Double; public var usable: Bool }
public enum RefreshRatePicker { public static func lowest(of modes: [DisplayModeInfo], current: DisplayModeInfo) -> DisplayModeInfo? }
public enum MeasurementPause {
    /// Whether Anode's sampling tick runs. Never paused while fans are driven or the charge floor is being watched.
    public static func ticks(ultraOn: Bool, windowWorthDrawing: Bool, drivingFans: Bool, chargeWatching: Bool) -> Bool
}
```

- [ ] **Step 1: Write the failing tests**

```swift
func testBrightnessAboveHalfIsPulledToHalf()                     // 0.8 → 0.5; 1.0 → 0.5
func testBrightnessAtOrBelowHalfIsLeftAlone()                    // 0.5, 0.505, 0.2 → nil
func testOldBrightnessComesBackWhenStillAtTheCeiling()           // before 0.8, now 0.5 → 0.8
func testBrightnessIsNotRaisedBackWhenTheOwnerWentDimmer()       // before 0.8, now 0.3 → nil
func testNothingToRestoreWhenTheModeDidNotLowerIt()              // before nil → nil
func testLowestRateAtTheSameResolution()                         // 120, 60, 59.94, 50, 48, 47.95 at 1800x1169 → 47.95
func testOtherResolutionsAndUnusableModesAreIgnored()
func testASixtyHertzOnlyScreenHasNothingLower()                  // [60] → nil
func testAlreadyAtTheLowestRateReturnsNil()
func testTickRunsNormallyWhenTheModeIsOff()
func testTickStopsWhenOnAndTheWindowIsClosed()
func testTickRunsWhileTheWindowIsOpen()
func testTickNeverStopsWhileFansAreDrivenOrTheChargeFloorIsWatched()
```

- [ ] **Step 2: Run** `swift test --filter UltraScreenTests`. Expected: FAIL, no type `BrightnessCeiling`.
- [ ] **Step 3: Implement**; point `UltraRecovery.actions` at `BrightnessCeiling.restore`.
- [ ] **Step 4: Run** `swift test --filter 'UltraScreenTests|UltraRecordTests'`. Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "Ultra low power mode: brightness ceiling, lowest rate, when Anode ticks"`.

---

### Task 6: Reading and stopping processes (glue)

**Files:**
- Create: `Sources/AnodeApp/UltraProcesses.swift`
- Test: `Tests/PowerKitTests/UltraProcessesTests.swift`

**Interfaces:**
- Consumes: `UltraProcess` (Task 3); the facts of Task 1 step 7 (how tap owners and audio input are found) and step 4 (hide delay).
- Produces:

```swift
protocol ProcessListing: AnyObject {
    /// Calls back on the main queue. nil when the list could not be read in full within `budget`.
    func snapshot(completion: @escaping ([UltraProcess]?) -> Void)
}
protocol ProcessFreezing: AnyObject {
    func stop(pid: pid_t, startTime: UInt64) -> Bool      // false when the pid is gone or is not that process any more
    func resume(pid: pid_t, startTime: UInt64) -> Bool
}
protocol AppHiding: AnyObject {
    /// Hides the app and calls back when it is hidden or `hideWait` has passed, whichever is first.
    func hide(pid: pid_t, completion: @escaping () -> Void)
    func unhide(pid: pid_t)
}
final class LiveProcessList: ProcessListing { static let budget: TimeInterval = 2.0 }
final class LiveProcessFreezer: ProcessFreezing { init(startTimeOf: @escaping (pid_t) -> UInt64? = LiveProcessList.startTime, signal: @escaping (pid_t, Int32) -> Int32 = kill) }
final class LiveAppHider: AppHiding { static let hideWait: TimeInterval = 1.0 }   // the delay Task 1 step 4 measured, if longer
```

`LiveProcessList` reads on a background queue: `proc_listallpids`, `proc_pidinfo(PROC_PIDTBSDINFO)` for parent, uid and start time, `proc_pidpath`, the responsible pid through `dlsym`, `NSRunningApplication` for kind, bundle id and name, the launchd label, tap owners and audio input as Task 1 found them. Its assembling step is a pure static function so it is tested without the system.

- [ ] **Step 1: Write the failing tests**

```swift
func testAssembleJoinsKernelFactsWithAppFacts()          // LiveProcessList.assemble(kernel:, apps:, tapOwners:, audioInput:, labels:)
func testAProcessWithNoReadablePathStillAppears()        // path ""
func testResponsibleEqualToItselfIsNil()
func testARecycledPidIsNeverSignalled()                  // startTimeOf returns another value → stop and resume return false, signal never called
func testStopSendsStopAndResumeSendsContinue()           // recorded (pid, SIGSTOP), (pid, SIGCONT) through the injected `signal`
func testAGonePidIsNotSignalled()                        // startTimeOf nil
```

- [ ] **Step 2: Run** `swift test --filter UltraProcessesTests`. Expected: FAIL, no type `LiveProcessList`.
- [ ] **Step 3: Implement.** The tests inject `signal`; nothing in the test target calls `kill`.
- [ ] **Step 4: Run** the filter. Expected: PASS, 6 tests.
- [ ] **Step 5: Commit** `git commit -m "Ultra low power mode: reading, stopping and hiding processes"`.

---

### Task 7: Screen, keyboard and watchdog (glue)

**Files:**
- Create: `Sources/AnodeApp/UltraDisplay.swift`, `Sources/AnodeApp/UltraWatchdog.swift`
- Modify: `Sources/PowerKit/LidDimmer.swift` (one shared record of the owner's own brightness), `Sources/AnodeApp/main.swift` (first line of the entry point: `UltraWatchdog.runIfRequested(CommandLine.arguments)`)
- Test: `Tests/PowerKitTests/UltraDisplayTests.swift`, `Tests/PowerKitTests/UltraWatchdogTests.swift`; extend the existing `LidDimmer` tests

**Interfaces:**
- Consumes: `BacklightControl`, `DisplayServicesBacklight` (existing); `RefreshRatePicker`, `DisplayModeInfo` (Task 5); `UltraRecord`, `UltraRecovery`, `UltraRecordFile` (Task 4); `ProcessFreezing` (Task 6); Task 1 steps 6 and 8.
- Produces:

```swift
protocol DisplayRateControlling: AnyObject {
    var canLower: Bool { get }          // false on a screen with one rate
    func lower() -> Bool                // app-scope configuration: reverts by itself if Anode dies
    func restore()
}
protocol KeyboardBacklightControlling: AnyObject { func level() -> Float?; func set(_ level: Float) -> Bool }
protocol UltraWatchdogging: AnyObject { func start(); func stop() }
final class LiveDisplayRate: DisplayRateControlling
final class LiveKeyboardBacklight: KeyboardBacklightControlling      // `level()` nil when Task 1 found no clean way
final class LiveUltraWatchdog: UltraWatchdogging { init(recordURL: URL) }   // starts this same executable with `--ultra-watchdog <pid> <record path>`
enum UltraWatchdog {
    static func runIfRequested(_ arguments: [String])     // returns at once unless the flag is there; else waits for the parent to exit, undoes, exits
    static func undo(record: UltraRecord, freezer: ProcessFreezing, backlight: BacklightControl) // resumes and restores brightness; unhiding waits for the next launch
}
public final class OwnBrightness { public static let shared: OwnBrightness
    public func remember(_ value: Float, for owner: String); public func forget(_ owner: String) -> Float? }  // the earliest remembered value wins
```

The watchdog waits on the parent's exit with a kernel event, not a poll. Rate needs no undoing (it reverts with the process); the power mode is the helper's to undo (Task 12).

- [ ] **Step 1: Write the failing tests**

```swift
func testModeListMapsToDisplayModeInfo()                  // LiveDisplayRate.info(from:) on stub values
func testWatchdogArgumentsAreParsed()                     // ["Anode", "--ultra-watchdog", "123", "/x/y.json"] → (123, "/x/y.json"); anything else → nil
func testUndoResumesWhatTheRecordNamesAndRestoresBrightness()  // fakes; a released group is not resumed
func testUndoWithNoRecordDoesNothing()
func testTwoOwnersShareOneRememberedBrightness()          // lid dimmer remembers 0.8, ceiling remembers 0.5 → the last to forget gets 0.8
```

- [ ] **Step 2: Run** `swift test --filter 'UltraDisplayTests|UltraWatchdogTests'`. Expected: FAIL, no type `LiveDisplayRate`.
- [ ] **Step 3: Implement.** `LidDimmer` saves and restores through `OwnBrightness`; its existing tests stay green.
- [ ] **Step 4: Run** `./test.sh --quick`. Expected: all pass.
- [ ] **Step 5: Commit** `git commit -m "Ultra low power mode: refresh rate, keyboard light, watchdog"`.

---

### Task 8: The controller

**Files:**
- Create: `Sources/AnodeApp/UltraLowPower.swift`
- Test: `Tests/PowerKitTests/UltraLowPowerControllerTests.swift` (fakes for every protocol; `schedule` injected)

**Interfaces:**
- Consumes: everything produced by Tasks 2 to 7.
- Produces:

```swift
enum PowerModeAvailability: Equatable { case ready, noHelper, oldHelper }
protocol PowerModeControlling: AnyObject {
    var availability: PowerModeAvailability { get }
    func enterLowPower(_ done: @escaping (_ modeBefore: Int?) -> Void)   // nil = could not
    func restore(_ mode: Int, _ done: @escaping (Bool) -> Void)
}
protocol UltraConfirming: AnyObject { func ask(kept: [String], frozen: [String], answer: @escaping (Bool) -> Void) }
enum UltraSkipped: Equatable { case lowPowerNoHelper, lowPowerOldHelper, oneRefreshRate, keyboardLight }
final class UltraLowPowerController {
    enum State: Equatable { case off, confirming, on }
    static let sweepSeconds: TimeInterval = 30
    static let didChange = Notification.Name("AnodeUltraLowPowerDidChange")
    static var current: UltraLowPowerController?
    init(settings: Settings, processes: ProcessListing, freezer: ProcessFreezing, hider: AppHiding, backlight: BacklightControl,
         rate: DisplayRateControlling, keyboard: KeyboardBacklightControlling, power: PowerModeControlling,
         watchdog: UltraWatchdogging, store: UltraRecordStoring, confirm: UltraConfirming,
         lastOtherFrontApp: @escaping () -> pid_t?, ownPIDs: @escaping () -> Set<pid_t>, user: uid_t,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void, log: @escaping (String) -> Void)
    private(set) var state: State
    private(set) var frozen: [FreezeGroup]            // still frozen
    private(set) var skipped: [UltraSkipped]
    var onChange: (() -> Void)?
    func request()                      // off → confirming; no-op otherwise
    func turnOff()                      // on → off
    func release(groupID: String)       // un-freeze one group for the rest of the session
    func appActivated(pid: pid_t)       // un-freezes the group that pid is in
    func sweep()                        // new members of frozen groups
    func brightnessMayHaveChanged()     // re-applies the ceiling
    func recoverAtLaunch()              // undoes a record left by a session that was not ended
    func shutdown()                     // quit, logout: same as turnOff, synchronous
    func isFrozen(pid: pid_t) -> Bool
}
```

Order when Confirm is pressed: save the record; start the watchdog; for each group, hide (regular apps), then stop, updating the record; brightness ceiling; rate; keyboard; Low Power Mode; state `.on`. Turning off runs `UltraRecovery.actions` on the live record through the same parts, then stops the watchdog and clears the record.

- [ ] **Step 1: Write the failing tests**

```swift
func testRequestShowsWhatWillBeKeptAndFrozenByName()      // confirm.asked == (kept: ["Editor"], frozen: ["Browser", "Sync"])
func testCancelChangesNothing()                           // no stop, no record, state .off
func testAFailedSnapshotStartsNothing()                   // snapshot nil → state .off, confirm never asked, logged
func testConfirmWritesTheRecordBeforeAnythingIsStopped()  // order of calls recorded across the fakes
func testConfirmHidesThenStopsEachGroup()
func testConfirmAppliesCeilingRateKeyboardAndLowPower()   // brightness 0.8 → 0.5; rate.lowered; keyboard 0; power entered
func testBrightnessBelowHalfIsNotTouchedOrRemembered()
func testNoHelperSkipsLowPowerAndSaysSo()                 // skipped == [.lowPowerNoHelper]; everything else done
func testOneRateScreenIsSkippedAndSaid()
func testTurnOffPutsEverythingBack()                      // all resumed, unhidden, 0.8, rate restored, power restored, record cleared, watchdog stopped
func testReleaseOneGroupLeavesTheRestFrozen()
func testAReleasedGroupIsNotRefrozenByTheSweep()
func testActivatingAFrozenAppReleasesIt()
func testSweepFreezesANewHelperOfAFrozenGroup()
func testSweepRunsOnlyWhileOn()                           // nothing scheduled in .off
func testBrightnessRaisedDuringTheSessionIsPulledBack()
func testRequestWhileOnOrConfirmingDoesNothing()
func testShutdownEndsTheSession()
func testRecoverAtLaunchUndoesALeftoverRecordAndStaysOff()
func testAGroupWhoseStopFailedIsNotListedAsFrozen()
```

- [ ] **Step 2: Run** `swift test --filter UltraLowPowerControllerTests`. Expected: FAIL, no type `UltraLowPowerController`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `./test.sh --quick`. Expected: all pass.
- [ ] **Step 5: Commit** `git commit -m "Ultra low power mode: controller"`.

---

### Task 9: Anode goes quiet

**Files:**
- Modify: `Sources/AnodeApp/main.swift` (the tick: `restartTimer`, `refresh`), `Sources/AnodeApp/MenuBarWidgets.swift` (render and click), `Sources/PowerKit/WallpaperPolicy.swift` and `Sources/AnodeApp/WallpaperConditionsSource.swift` (a pause reason), `Sources/AnodeApp/GameMode.swift` (does not show), `Sources/AnodeApp/BarReader.swift`, `WindowSwitcher.swift`, `WindowGroups.swift`, `WindowSnapping.swift`, `DockPreviews.swift` (never call into a stopped process)
- Test: `Tests/PowerKitTests/UltraQuietTests.swift`; extend `BarReaderTests`, the wallpaper policy tests and the game mode tests

**Interfaces:**
- Consumes: `MeasurementPause.ticks` (Task 5); `UltraLowPowerController.current`, `.isFrozen(pid:)`, `.state`, `.didChange` (Task 8).
- Produces:
  - `MenuBarWidgetController.pausedText = "Paused"`; `static func shownValue(paused: Bool, value: String) -> String`; `var isPaused: () -> Bool`; `var onPausedClick: ((NSStatusBarButton) -> Void)?` (a click on any reading while paused calls this, not the usual action).
  - `AppDelegate`'s tick runs only when `MeasurementPause.ticks(...)` is true; the timer is removed, not slowed, while it is false, and history recording stops with it.
  - `WallpaperPauseReason.ultraLowPower` (wins over the owner's preferences); the game strip does not show while the mode is on.
  - `AXBarReader`: a frozen pid is not asked; its items from the last complete read are reused, so the hider's covers stay where they were.
  - Window switcher, groups, snapping and Dock previews skip frozen pids when listing; choosing a frozen app's window calls `release(groupID:)` first.

- [ ] **Step 1: Write the failing tests**

```swift
func testEveryReadingShowsPausedWhileTheModeIsOn()        // shownValue(paused: true, value: "12%/hr") == "Paused"
func testReadingsShowTheirValuesOtherwise()
func testAClickOnAPausedReadingOpensTheModesMenu()        // onPausedClick called, the usual action not
func testWallpaperPausesForUltraLowPowerWhateverThePreferences()
func testTheGameStripDoesNotShowWhileTheModeIsOn()
func testAFrozenAppsBarItemsAreReusedNotAsked()           // BarReaderTests: reuse(previous:, frozen:) keeps its items; a pid that is gone is dropped
func testFrozenAppsAreLeftOutOfTheWindowList()
```

- [ ] **Step 2: Run** `swift test --filter 'UltraQuietTests|BarReaderTests'`. Expected: FAIL, no member `shownValue`.
- [ ] **Step 3: Implement.** Sensor-holding and safety features (charge control, fan control, Keep Awake) keep their own timers; only the measuring tick is gated.
- [ ] **Step 4: Run** `./test.sh --quick`. Expected: all pass.
- [ ] **Step 5: Commit** `git commit -m "Ultra low power mode: Anode pauses its measuring"`.

---

### Task 10: Confirm box, menu and section

**Files:**
- Create: `Sources/AnodeApp/UltraLowPowerFeature.swift` (the Beta section, `UltraConfirmPanel`, `UltraMenu`, `UltraIcon`)
- Modify: `Sources/AnodeApp/BetaFeaturesWindow.swift` (add `UltraLowPowerFeature()` to `defaultFeatures`), `Sources/AnodeApp/Shortcuts.swift` (`ShortcutCommands.ultraToggle`, id `ultra.toggle`, ⌃⌥⌘U; `ShortcutCommands.ultra`), `Sources/AnodeApp/AppMenu.swift` (the entry)
- Test: `Tests/PowerKitTests/UltraLowPowerFeatureTests.swift`; one case in `ShortcutsTests`

**Interfaces:**
- Consumes: `UltraLowPowerController` (Task 8); `Settings` keys (Task 2); the measured numbers of Task 1 for the note.
- Produces:

```swift
final class UltraConfirmPanel: UltraConfirming            // non-activating panel: it must not take the front app's place
enum UltraMenu {
    static func build(state: UltraLowPowerController.State, frozen: [FreezeGroup], onStart: @escaping () -> Void,
                      onTurnOff: @escaping () -> Void, onRelease: @escaping (String) -> Void, onOpenBeta: @escaping () -> Void) -> NSMenu
    static func confirmText(kept: [String], frozenCount: Int) -> String
}
protocol UltraIconPresenting: AnyObject { func install(); func remove() }   // one small status item, used only when no reading is on the bar
final class UltraLowPowerFeature: BetaFeature {
    static func describe(_ skipped: [UltraSkipped]) -> [String]       // one plain line per part this Mac cannot do
    static let note: String                                           // what was measured, in plain words
}
```

Section contents, top to bottom: the enable checkbox; the Start / Turn off button (disabled while unticked); the "always keep" list with add (a picker of running groups by name) and remove; the skipped-part lines; the note.

- [ ] **Step 1: Write the failing tests**

```swift
func testConfirmTextNamesWhatIsKeptAndCountsWhatFreezes() // "Keeps Editor and Meetings. Freezes 9 apps and tools until you turn this off."
func testMenuWhenOffOffersToStart()                       // titles: "Ultra Low Power Mode…"
func testMenuWhenOnListsTurnOffAndEveryFrozenGroup()      // "Turn off", then one item per group, by name
func testChoosingAFrozenGroupReleasesIt()                 // the item's action calls onRelease with the group id
func testEachSkippedPartHasAPlainLine()                   // .lowPowerNoHelper → a line that names the helper and what to do
func testTheNoteMakesNoPromiseOfRunningTime()             // contains "no running time is promised"; does not contain "hours"
func testTheNoteDoesNotSellTheRefreshRate()               // contains "little or nothing"
func testSectionIsInTheBetaFeaturesList()
func testUltraShortcutIsControlOptionCommandU()           // ShortcutsTests
```

- [ ] **Step 2: Run** `swift test --filter 'UltraLowPowerFeatureTests|ShortcutsTests'`. Expected: FAIL, no type `UltraMenu`.
- [ ] **Step 3: Implement.** The note's numbers come from the results file of Task 1; if a number was not measured, the sentence is left out.
- [ ] **Step 4: Run** `./test.sh --quick`. Expected: all pass.
- [ ] **Step 5: Commit** `git commit -m "Ultra low power mode: confirm box, menu and section"`.

---

### Task 11: Wiring

**Files:**
- Create: `Sources/AnodeApp/UltraLowPowerRuntime.swift`
- Modify: `Sources/AnodeApp/main.swift` (create the runtime beside `menuBarHider`; `shutdown()` in `applicationWillTerminate`)
- Test: `Tests/PowerKitTests/UltraLowPowerWiringTests.swift`

**Interfaces:**
- Consumes: Tasks 2 to 10; `KeybindCenter.shared.register(owner:commands:handler:)` / `unregister(owner:)`; `MenuBarWidgetController`; Task 1 step 3 (whether activation is reported) and step 6 (how the ceiling is held).
- Produces: `final class UltraLowPowerRuntime` with `static func live(widgets: MenuBarWidgetController, openBetaFeatures: @escaping () -> Void) -> UltraLowPowerRuntime`, `let controller`, `func shutdown()`; an `init` taking every part, the `register`/`unregister` closures and a notification source, for the tests.

Rules: with the checkbox unticked nothing exists but the settings observer. Ticked: the shortcut is registered, the menu entries appear, and the last front app other than Anode is tracked (it is what `lastOtherFrontApp` answers). While on: the 30 s sweep, the brightness watch, `didActivateApplication` → `appActivated`, `willPowerOff` and `applicationWillTerminate` → `shutdown`, every reading paused and its click opening `UltraMenu`, the icon only when no reading is on the bar. Unticking the checkbox while on turns the mode off first. At launch: `recoverAtLaunch()` before anything else of the feature.

- [ ] **Step 1: Write the failing tests**

```swift
func testNothingExistsWhileUnticked()                     // shortcut not registered, no observers, no timers
func testTickingRegistersTheShortcutAndNothingStarts()    // state .off
func testTheShortcutAsksForTheMode()                      // confirm asked
func testTheKeptAppIsTheLastFrontAppOtherThanAnode()      // editor activated, then Anode → the plan's front is the editor
func testUntickingWhileOnTurnsTheModeOffFirst()
func testPowerOffAndQuitEndTheSession()                   // posted willPowerOff → everything resumed
func testActivationOfAFrozenAppReleasesIt()
func testTheSweepAndBrightnessWatchRunOnlyWhileOn()
func testLaunchRecoversALeftoverRecord()
func testTheIconAppearsOnlyWhenNoReadingIsOnTheBar()
```

- [ ] **Step 2: Run** `swift test --filter UltraLowPowerWiringTests`. Expected: FAIL, no type `UltraLowPowerRuntime`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `./test.sh --quick`. Expected: all pass.
- [ ] **Step 5: Commit** `git commit -m "Ultra low power mode: wiring"`.

---

### Task 12: Low Power Mode through the helper

Only after the charge feature's helper files are final.

**Files:**
- Modify: `Sources/PowerKit/FanControl.swift` (`FanCommand`), `Sources/PowerKit/FanHelperService.swift` (`handle`), `Sources/PowerKit/FanDaemon.swift` (`protocolVersion`, the `FanElevation` disclosure text), `Sources/AnodeApp/HelperConnection.swift` (a `speaksPowerMode` beside `speaksCharge`)
- Create: `Sources/AnodeApp/UltraPowerMode.swift` (`final class HelperPowerMode: PowerModeControlling`)
- Test: extend the helper's command, service and disclosure tests in the style of the charge commands; `Tests/PowerKitTests/UltraPowerModeTests.swift`

**Interfaces:**
- Consumes: `PowerModeControlling` (Task 8); the helper's command pattern as the charge feature left it.
- Produces: `FanCommand.setPowerMode(lowPower: Bool)` (the helper reads the battery power mode, remembers it for this connection, sets low power or puts the remembered mode back, and replies with the mode before); `protocolVersion` one higher; the mode put back by the helper itself when the app's connection closes without a restore; one sentence in the disclosure text naming this.

- [ ] **Step 1: Write the failing tests**

```swift
func testSetPowerModeRoundTripsThroughTheWire()
func testLowPowerRemembersTheModeBeforeAndRepliesWithIt()     // fake pmset: before 2 → sets 1, reply 2
func testRestorePutsBackTheRememberedMode()
func testAClosedConnectionPutsTheModeBack()                   // release, not hold
func testAModeThisFeatureDidNotSetIsNotTouchedOnClose()
func testTheDisclosureNamesThePowerMode()
func testAnOlderHelperIsReportedAsOld()                       // HelperPowerMode.availability == .oldHelper
func testNoHelperIsReportedAsMissing()
```

- [ ] **Step 2: Run** the helper test filters and `UltraPowerModeTests`. Expected: FAIL, no case `setPowerMode`.
- [ ] **Step 3: Implement.** The privileged call goes through an injected runner; the tests never run `pmset`.
- [ ] **Step 4: Run** `./test.sh --quick` and `Tests/installer-tests.sh`. Expected: all pass.
- [ ] **Step 5: Commit** `git commit -m "Ultra low power mode: low power mode through the helper"`.

---

### Task 13: On the owner's Mac, then release

**Files:**
- Modify: `docs/superpowers/plans/2026-11-12-ultra-low-power-mode-results.md`, `build-app.sh` (`VERSION`), `CHANGELOG.md`, `UPDATE-NOTE.md`

Tell the other session before starting. The helper must be reinstalled once (password).

- [ ] **Step 1:** `./build-app.sh`; confirm `BSSourceCommit` equals `git rev-parse --short HEAD`, the running inode equals the installed binary's, and `codesign --verify <pid>` passes.
- [ ] **Step 2: A real session.** Tick the checkbox, start from the shortcut with the editor in front. Expected: the box names the editor and lists the rest; after Confirm the readings say "Paused", other apps' windows are gone, brightness is at half, the rate is the lowest, Low Power Mode is on; the editor, its terminal and a build all work.
- [ ] **Step 3: Getting one back.** Un-freeze one app from a "Paused" reading's menu, and one from the Dock. Expected: both return with their windows.
- [ ] **Step 4: Turning off.** Expected: every app back, brightness, rate, keyboard light and power mode as before, readings live. `ps -axo stat | grep -c T` is 0.
- [ ] **Step 5: Killing Anode** with the mode on (`kill -9`). Expected: everything continues within a second; brightness back; the rate back; the helper puts the power mode back; the next launch finds nothing left to undo.
- [ ] **Step 6: Quit, sleep and wake** with the mode on. Expected: quit undoes everything; sleep and wake leave the session as it was.
- [ ] **Step 7: Logout** with the mode on, at a moment the owner picks (it ends every open session on the Mac). Expected: the logout is not held up.
- [ ] **Step 8: Power.** Ten minutes on battery at a quiet Mac with the mode on; record whole-Mac watts in the results file and correct the section's note if it differs.
- [ ] **Step 9: Release files.** Next minor version in `build-app.sh`, the entry at the top of `CHANGELOG.md`, two plain sentences in `UPDATE-NOTE.md`; `./test.sh --quick` green; commit `git commit -m "Release <version>: ultra low power mode"`. Merge, tag and push only on the owner's word.
