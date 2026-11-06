# Per-App Volume Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Beta Features section that lists the apps making sound and gives each one its own volume (0–200 %) and a mute, without a driver or any system-wide change.

**Architecture:** For each app the user has changed, Anode makes a *private Core Audio process tap* on that app's audio processes (original output muted by the tap), feeds the tap into a private aggregate device whose output is the current default output device, and passes the audio through a gain stage (ramped gain, hard clamp) in the aggregate's IO callback. No tap exists for an app left at its defaults, so the idle cost is zero. The gain stage, settings, app grouping and the router are pure/injected and unit-tested; the Core Audio session is a thin layer verified on hardware. **Task 1 is a measured go/no-go with the owner present; several behaviours this design depends on are unverified on macOS 27.**

**Tech Stack:** Swift 5.9, CoreAudio (`CATapDescription`, `AudioHardwareCreateProcessTap` — macOS 14.2+, present in the installed SDK), AppKit, XCTest (`Tests/PowerKitTests`).

**Spec:** the owner's backlog entry of 2026-10-29: "Per-app volume + EQ — reference https://betteraudio.pro/", "remember this for later". **Revised 2026-11-06: no EQ.** The owner's reason: AirPods have a built-in EQ and most Mac users have AirPods. That app is reference for behaviour only. The design is built from Apple's headers (`CATapDescription.h`, `AudioHardwareTapping.h`) and documentation; no third-party code is copied. Decisions beyond the entry are marked *(author's call)*.

## Global Constraints

- Beta Features section "App Volume", **off by default** (`appAudioEnabled`). While off, or while no app is changed: **no tap, no aggregate device, no IO callback, no timer** (the app must stay light on battery).
- Per app: **volume 0–200 %** (gain `0...2`, default 1) and **mute**. **No EQ, no tone controls** (owner decision above). Settings are keyed by bundle id and persist (`anode.appAudio.v1` in `dev.anode.app`).
- The tap is **private** (`privateTap = true`) and uses `muteBehavior = .muted`; the tapped app's own output is silenced only while Anode's session for it is alive. If Anode dies the app must be audible again on its own (verified in Task 1, relied on in Task 9).
- All processes of an app are tapped together: helpers (e.g. a browser's audio-service helper) are grouped to the **outermost `.app`** their executable lives in.
- The IO callback never allocates, never takes a lock, and never calls Objective-C or Swift runtime-heavy APIs. The only value that reaches it from other threads is the target gain, through one aligned 32-bit float store (atomic on arm64; nothing else is published with it, so no barrier is needed).
- Mute is a target gain of 0. Every gain change, including mute and unmute, is ramped linearly over **10 ms** (`rampSeconds = 0.010`) regardless of buffer size, so a slider or the mute button never clicks; output is hard-clamped to ±1.
- Output device changes (headphones, Bluetooth, AirPlay), sleep/wake and the default sample rate changing rebuild every session; a failed session is removed, the app returns to normal, and the row says "Couldn't control this app" while the saved setting is kept.
- Needs the **Audio Recording** privacy permission: add `NSAudioCaptureUsageDescription` to the Info.plist in `build-app.sh`. Ad-hoc signed builds may lose the grant on rebuild (see the README note and `make-signing-identity.sh`).
- A muted original with a silent tap must never leave an app silent without the user knowing: what "no permission" does is measured in Task 1 and handled in Task 7.
- Package target stays macOS 13: gate every tap call with `#available(macOS 14.2, *)`; below it the toggle is disabled with "needs macOS 14.2 or later". New branch `app-audio` off `main`; never commit to `main`. Test command: `swift test --filter <TestClass>`.
- The owner is using the Mac: automated tests never create a real tap, aggregate device or sound. Real audio is exercised only in Tasks 1 and 9, when the owner says so, with their volume low.
- Last step: `./build-app.sh`, confirm `BSSourceCommit` equals `git rev-parse --short HEAD` and the running process's inode matches the installed binary.

## Review Focus

- An app starts playing *after* its setting was changed: the tap appears a moment after the first sound, so the first fraction of a second is unadjusted; the plan measures it and the section says so. (Tasks 1, 5)
- A tapped app opens a new helper process mid-session (a browser tab): the session is rebuilt with the new process ids without a gap longer than the measured figure. (Task 5)
- The output device changes while sessions exist (AirPods connect): sessions follow it; none is left writing to a vanished device. (Task 5)
- Permission refused or revoked: no app is left muted by a tap that delivers silence; the section explains and offers the Settings button. (Tasks 1, 7)
- Mono sources, 5.1/spatial output, and a device whose sample rate is not 44.1/48 kHz: the gain stage is correct for any channel count and rate. (Task 3)

## File Structure

| File | Responsibility |
|---|---|
| `Sources/PowerKit/Settings.swift` (modify) | `appAudioEnabled` |
| `Sources/PowerKit/AppAudioSetting.swift` (create) | `AppAudioSetting`, `AppAudioStore` |
| `Sources/PowerKit/GainStage.swift` (create) | `GainStage` (ramped gain, clamp) |
| `Sources/PowerKit/AudioAppGrouping.swift` (create) | `AudioProcessInfo`, `AudioApp`, outermost-bundle grouping |
| `Sources/AnodeApp/AppAudioBackend.swift` (create) | `AppAudioBackend` / `AppAudioSessionHandle` protocols + the real Core Audio backend |
| `Sources/AnodeApp/AppAudioRouter.swift` (create) | which apps get a session; follows devices and process changes |
| `Sources/AnodeApp/BetaFeaturesWindow.swift` (modify) | `AppAudioFeature` section (one row per app), added to the list in `init` |
| `Sources/AnodeApp/main.swift` (modify) | construct the router beside `keepAwake` (~line 321) |
| `build-app.sh` (modify) | `NSAudioCaptureUsageDescription` |
| `Tests/PowerKitTests/AppAudioSettingTests.swift`, `GainStageTests.swift`, `AudioAppGroupingTests.swift`, `AppAudioRouterTests.swift`, `AppAudioFeatureTests.swift` (create) | tests per task |

---

### Task 1: Spike, go / no-go (owner present, volume low)

**Files:** a probe in the session scratchpad only; findings recorded in this file under "Measured".

- [ ] **Step 1: Ask the owner** to play something in one app (e.g. a YouTube tab in Brave) at low volume and to expect the Audio Recording permission dialog. Do not run otherwise.
- [ ] **Step 2: Write a command-line probe** (scratchpad) that lists `kAudioHardwarePropertyProcessObjectList` with each process's pid, bundle id and `kAudioProcessPropertyIsRunningOutput`; records which objects belong to the playing app (is it the app itself or a helper?).
- [ ] **Step 3: Extend the probe** to build `CATapDescription(stereoMixdownOfProcesses:)` with `isPrivate = true`, `muteBehavior = .muted`, create the tap and a private aggregate device (`kAudioAggregateDeviceMainSubDeviceKey` and a sub-device both the default output's UID, `kAudioAggregateDeviceTapListKey` with `kAudioSubTapDriftCompensationKey = 1`), start an IO proc that copies input to output at gain 0.5, and run 10 s. Record: it works (owner hears it quieter); `kAudioTapPropertyFormat` (sample rate, channels, interleaved or not); aggregate `kAudioDevicePropertyLatency + SafetyOffset + BufferFrameSize` against the plain output device's, i.e. the **added latency in ms**.
- [ ] **Step 4: Permission.** Revoke Audio Recording for the probe's host (System Settings → Privacy & Security) and rerun. Record exactly what happens: does `AudioHardwareCreateProcessTap` fail, or succeed with zeros? Is the app left silent? Is there a way to preflight (public API, or `TCCAccessPreflight`-style private call via `dlsym`) and does it agree with reality?
- [ ] **Step 5: Safety.** While the probe mutes the app, `kill -9` the probe. Record whether the app's audio returns immediately.
- [ ] **Step 6: Follow-ups.** With a session running, (a) open a second tab/helper that starts audio; (b) switch the output device (built-in speakers ↔ AirPods/AirPlay); (c) put the Mac to sleep and wake it. Record what happens to the tap and how long the unadjusted gap is when playback starts after the tap was requested.
- [ ] **Step 7: Decide.** GO if: the tap works on a helper-process browser, the added latency is small enough that a video does not look out of sync (target under 40 ms; the owner judges by watching a speaking face), a refused permission is detectable or harmless, and `kill -9` returns the app's sound. Otherwise stop and report; the alternative (a virtual audio driver) needs root installation and is a different plan.
- [ ] **Step 8: Record** the measurements and the exact aggregate dictionary that worked here, and commit "App audio: spike results".

### Task 2: Setting and per-app store

**Files:**
- Modify: `Sources/PowerKit/Settings.swift` (follow `keepAwakeEnabled` at each of its six spots)
- Create: `Sources/PowerKit/AppAudioSetting.swift`
- Test: `Tests/PowerKitTests/AppAudioSettingTests.swift`

**Interfaces:**
- Produces: `settings.appAudioEnabled: Bool` (default false); `public struct AppAudioSetting: Codable, Equatable { public var gain: Float; public var muted: Bool; public static let flat: AppAudioSetting; public var isDefault: Bool; public var effectiveGain: Float; public static let gainRange: ClosedRange<Float> }` (`effectiveGain` is `muted ? 0 : gain`); `public final class AppAudioStore { public init(defaults: UserDefaults, key: String = "anode.appAudio.v1"); public func setting(for bundleID: String) -> AppAudioSetting; public func set(_ s: AppAudioSetting, for bundleID: String); public func reset(_ bundleID: String); public var customised: [String: AppAudioSetting] { get }; public static let didChange: Notification.Name }`.

- [ ] **Step 1: Write the failing tests.** Setting default false and persistence; `AppAudioSetting.flat.isDefault`; muted at gain 1 is not default and has `effectiveGain == 0`; gain clamps to `0...2` on `set` and on decode; `set` of a default setting removes the entry (`customised` stays empty); round trip through a second `AppAudioStore` on the same defaults; `reset` removes; `didChange` posts once per real change; corrupt JSON in defaults yields empty, not a crash; a stored entry that still carries an `eq` field from a draft is decoded and the field ignored.
- [ ] **Step 2: Run** `swift test --filter AppAudioSettingTests`. Expected: FAIL.
- [ ] **Step 3: Implement** both.
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Commit** "App audio: setting and per-app store".

### Task 3: The gain stage

**Files:**
- Create: `Sources/PowerKit/GainStage.swift`
- Test: `Tests/PowerKitTests/GainStageTests.swift`

**Interfaces:**
- Produces: `public final class GainStage { public init(channels: Int, sampleRate: Double, initialGain: Float); public func setTarget(_ gain: Float); public func render(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frames: Int) }` (interleaved, `channels` samples per frame; `setTarget` from any one non-audio thread, `render` from the audio thread only; `rampSeconds = 0.010`).

- [ ] **Step 1: Write the failing tests:**
  - `testUnityIsBitIdentical`: random 4096-frame stereo buffer at `initialGain: 1` and target 1 equals the input exactly.
  - `testGainHalvesTheAmplitudeAfterTheRamp`: target 0.5, a 440 Hz sine of amplitude 0.8 → peak 0.4 ± 0.01 after the first 10 ms.
  - `testRampTakesTenMillisecondsWhateverTheBufferSize`: from 1 to 0 with 64-frame and with 4096-frame buffers at 48 kHz, the output reaches exactly 0 at frame 480 ± 1 in both cases.
  - `testMuteAndUnmuteNeverStep`: a constant 0.5 input, mute then unmute; the largest sample-to-sample change never exceeds `0.5 / (0.010 * sampleRate) + 1e-6`.
  - `testGainAboveOneClampsAtOne`: target 2, amplitude 0.8 sine → no sample outside ±1.
  - `testAnyChannelCountAndRate`: mono, stereo and 6-channel buffers at 44100 and 96000 behave the same; a signal on channel 0 only leaves the other channels silent.
  - `testTargetChangesWhileRenderingStayFinite`: 200 alternating `setTarget` and `render` calls on one thread; every output sample finite.
- [ ] **Step 2: Run** `swift test --filter GainStageTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** Target in a single preallocated `UnsafeMutablePointer<Float>`; current gain and per-sample step as plain stored properties updated only by `render`; no Swift arrays, closures or class allocations inside `render`.
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Commit** "App audio: gain stage".

### Task 4: Grouping processes into apps

**Files:**
- Create: `Sources/PowerKit/AudioAppGrouping.swift`
- Test: `Tests/PowerKitTests/AudioAppGroupingTests.swift`

**Interfaces:**
- Produces: `public struct AudioProcessInfo: Equatable { public let objectID: UInt32; public let pid: Int32; public let executablePath: String; public let isRunningOutput: Bool }`; `public struct AudioApp: Equatable { public let bundleID: String; public let name: String; public let appPath: String; public var processObjectIDs: [UInt32]; public var isPlaying: Bool }`; `public enum AudioAppGrouping { public static func outermostAppPath(_ executablePath: String) -> String?; public static func group(_ processes: [AudioProcessInfo], bundleID: (String) -> String?, name: (String) -> String) -> [AudioApp] }`.

- [ ] **Step 1: Write the failing tests:** `outermostAppPath("/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework/Versions/1/Helpers/Brave Browser Helper.app/Contents/MacOS/Brave Browser Helper")` is `"/Applications/Brave Browser.app"`; a plain `/usr/bin/afplay` returns nil; a path with `.app` only as a suffix of a non-bundle directory name (e.g. `/tmp/x.application/y`) returns nil. `group`: four processes (app + three helpers, one running output) become one `AudioApp` with four ids and `isPlaying == true`; two different apps stay two; a process whose path has no app bundle is dropped; results are sorted playing-first, then by name case-insensitively; `bundleID` closure returning nil drops the app.
- [ ] **Step 2: Run** `swift test --filter AudioAppGroupingTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** Pure string work on path components.
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Commit** "App audio: group audio processes into apps".

### Task 5: The backend protocols and the router

**Files:**
- Create: `Sources/AnodeApp/AppAudioBackend.swift` (protocols only in this task), `Sources/AnodeApp/AppAudioRouter.swift`
- Test: `Tests/PowerKitTests/AppAudioRouterTests.swift`

**Interfaces:**
- Consumes: `AppAudioSetting`, `AppAudioStore`, `GainStage`, `AudioApp`, `AudioProcessInfo`, `AudioAppGrouping`, `Settings.appAudioEnabled`.
- Produces:
  - `enum AudioCapturePermission: Equatable { case granted, denied, unknown }`
  - `protocol AppAudioSessionHandle: AnyObject { func stop() }`
  - `protocol AppAudioBackend: AnyObject { func processes() -> [AudioProcessInfo]; func defaultOutputUID() -> String?; func start(tapping processObjectIDs: [UInt32], outputUID: String, gain: GainStage, onFailure: @escaping () -> Void) throws -> AppAudioSessionHandle; func permission() -> AudioCapturePermission; var onProcessesChanged: (() -> Void)? { get set }; var onOutputChanged: (() -> Void)? { get set } }`
  - `final class AppAudioRouter { static weak var current: AppAudioRouter?; init(settings: Settings, store: AppAudioStore, backend: AppAudioBackend, bundleID: @escaping (String) -> String?, name: @escaping (String) -> String); func apps() -> [AudioApp]; func reconcile(); func shutdown(); private(set) var failures: [String: String]; var permission: AudioCapturePermission { get }; var activeSessionCount: Int; var onChange: (() -> Void)? }`

- [ ] **Step 1: Write the failing tests** with a `FakeBackend` (scripted processes/output UID/permission, records `start`/`stop`):
  - `testNoSessionsWhileEveryAppIsAtDefaults` (including the feature on).
  - `testChangingAnAppStartsOneSessionWithAllItsProcessIds`.
  - `testSessionUsesTheStoredGain` (the `GainStage` handed to `start` renders at the stored gain; a later store change moves its target; mute moves it to 0).
  - `testResettingToDefaultStopsTheSession`.
  - `testNewHelperProcessRestartsTheSessionWithTheNewIds` (`onProcessesChanged` fired with an extra process).
  - `testOutputDeviceChangeRestartsEverySessionOnTheNewUID`.
  - `testStartFailureIsRecordedAndTheSettingKept` (`failures["com.x"] != nil`, `store.setting(for:)` unchanged, no retry loop: a second `reconcile()` without a trigger does not retry).
  - `testOnFailureCallbackRemovesTheSessionAndRecordsIt`.
  - `testDisablingTheFeatureStopsEverySessionOnce`.
  - `testAppNotRunningHasNoSessionButKeepsItsSetting`; starting it later (processes appear) creates the session.
  - `testNoDefaultOutputMeansNoSessions`.
  - `testDeniedPermissionStartsNoSessionAndIsReported` (`backend.permission() == .denied` → no `start` call, `router.permission == .denied`, no app muted).
  - `testShutdownStopsEverySessionAndIgnoresLaterEvents` (a process-list event after `shutdown()` starts nothing).
- [ ] **Step 2: Run** `swift test --filter AppAudioRouterTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the protocols and `AppAudioRouter` (main thread; one `GainStage` per session, `setTarget` when the store changes via `AppAudioStore.didChange`; sessions keyed by bundle id with the process ids and output UID they were built for; `reconcile()` diffs desired vs actual). No timer.
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Commit** "App audio: router".

### Task 6: The Core Audio backend

**Files:**
- Modify: `Sources/AnodeApp/AppAudioBackend.swift` (add `CoreAudioBackend`)
- Test: none automated (real devices); a build check and Task 9.

**Interfaces:**
- Consumes: the protocols (Task 5), `GainStage` (Task 3), the Task 1 dictionary and format findings.
- Produces: `final class CoreAudioBackend: AppAudioBackend` and `final class CoreAudioSession: AppAudioSessionHandle`.

- [ ] **Step 1: Implement `CoreAudioBackend.processes()`** from `kAudioHardwarePropertyProcessObjectList`, reading `kAudioProcessPropertyPID`, `kAudioProcessPropertyIsRunningOutput`, and the executable path with `proc_pidpath`; `defaultOutputUID()` from `kAudioHardwarePropertyDefaultOutputDevice` + `kAudioDevicePropertyDeviceUID`; `permission()` as Task 1 found possible (`.unknown` if nothing reliable exists); property listeners (block-based, main queue) on the process list and on the default output device call `onProcessesChanged` / `onOutputChanged` and are removed in `deinit`.
- [ ] **Step 2: Implement `CoreAudioSession`** (`#available(macOS 14.2, *)`): the exact tap and aggregate construction Task 1 proved; the IO block calls `gain.render` per buffer (converting if Task 1 found a non-interleaved format, using a preallocated scratch buffer sized at start); `stop()` stops the device, destroys the IO proc, the aggregate and the tap, in that order, and is idempotent; any `OSStatus` failure at start tears down what was built and throws; a `kAudioDevicePropertyDeviceIsAlive` listener or an IO error calls `onFailure`.
- [ ] **Step 3: Build** `swift build`. Expected: clean, no new warnings.
- [ ] **Step 4: Commit** "App audio: Core Audio backend".

### Task 7: Permission, Info.plist and the Beta Features section

**Files:**
- Modify: `build-app.sh` (Info.plist block, ~line 112-145), `Sources/AnodeApp/BetaFeaturesWindow.swift` (`AppAudioFeature`, added to the list in `init`)
- Test: `Tests/PowerKitTests/AppAudioFeatureTests.swift`

**Interfaces:**
- Consumes: `AppAudioRouter.current`, `AppAudioStore`, `AppAudioSetting`.
- Produces: `final class AppAudioFeature: BetaFeature` with `enableCheckbox`, `permissionLabel`, `permissionButton`, `rowsStack`; `final class AppAudioRow: NSStackView` with `slider` (0–200), `muteButton`, `statusLabel`; `static func sliderValue(for gain: Float) -> Double` and `static func gain(forSliderValue: Double) -> Float` (pure, inverse of each other).

- [ ] **Step 1: Write the failing tests** (a router over `FakeBackend`, shape of `KeepAwakeUITests`): the checkbox writes `appAudioEnabled`; with two playing apps and one customised-but-silent app the stack has three rows, playing first, the silent one dimmed; moving a row's slider to 50 stores gain 0.5 for that bundle id; the mute button toggles `muted` and the slider keeps its position; a row whose bundle id is in `router.failures` shows "Couldn't control this app" and keeps its controls; with `router.permission == .denied` the permission label and button appear and rows are disabled; below macOS 14.2 the checkbox is disabled with the version text; slider/gain mapping round-trips for 0, 0.5, 1, 2.
- [ ] **Step 2: Run** `swift test --filter AppAudioFeatureTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** Add `NSAudioCaptureUsageDescription` = "Anode changes the volume of individual apps by listening to their audio and playing it back adjusted. Nothing is recorded or stored." to the Info.plist heredoc. The section's rows refresh on `refresh()` and on a 2 s timer owned by the feature that invalidates itself when `view.window?.isVisible != true`; the list is also refreshed by the router's `onChange`. Summary: "Give each app its own volume, or mute it. Needs the Audio Recording permission. The first fraction of a second after an app starts playing can come through at its old volume." Permission handling follows exactly what Task 1 measured (preflight if one exists, otherwise a guard that tears a session down and shows the permission message if `isRunningOutput` stays true while the tap delivers only zeros for 3 s).
- [ ] **Step 4: Run** the class plus `swift test --filter BetaLayoutTests`. Expected: PASS.
- [ ] **Step 5: Commit** "App audio: Beta Features section".

### Task 8: Wiring and quit-time cleanup

**Files:**
- Modify: `Sources/AnodeApp/main.swift` (construct `AppAudioRouter` with `CoreAudioBackend`, set `AppAudioRouter.current`; call `router.shutdown()` from `applicationWillTerminate`)
- Test: covered by `testShutdownStopsEverySessionAndIgnoresLaterEvents` (Task 5); this task is wiring only.

- [ ] **Step 1: Wire** the router in `main.swift` beside `keepAwake` (~line 321) and call `shutdown()` on terminate.
- [ ] **Step 2: Run** `swift build` and `swift test --filter AppAudioRouterTests`. Expected: clean build, PASS.
- [ ] **Step 3: Commit** "App audio: wiring and shutdown".

### Task 9: On-hardware verification (only when the owner says so)

**Files:** none; record findings under "Measured" in this file.

- [ ] **Step 1: Build and install** (`./build-app.sh`). Owner enables App Volume and grants Audio Recording. Expected: rows for the apps currently playing.
- [ ] **Step 2: By ear.** Owner plays music in one app and a video in a browser: each slider changes only its own app; mute silences only that app; no clicks when dragging or muting; no audible delay between a speaking face and its voice.
- [ ] **Step 3: Devices.** Switch output (speakers ↔ AirPods/AirPlay) mid-playback. Expected: control continues on the new device within about a second.
- [ ] **Step 4: Failure paths.** Quit Anode while an app is muted (app returns at once); `kill -9` it (app returns at once); revoke the permission while a session is running (the app is not left silent; the section explains).
- [ ] **Step 5: Cost.** With one app controlled, measure Anode's CPU over 60 s with `ps` time deltas (the method in the Beta Features notes); with no app changed, confirm there is no aggregate device (`system_profiler SPAudioDataType` shows none from Anode) and CPU equals the baseline of 0.27 % of a core with the window closed.
- [ ] **Step 6: Record** the results (added latency, unadjusted gap at playback start, CPU) and commit "App audio: verified on hardware".

### Task 10: Optional second stage, after the owner has tried it — a menu bar popover

**Files:** to be decided with the owner after Task 9; not started until they ask. The idea: a speaker icon in the menu bar that opens the same rows (`AppAudioRow`) in a popover, because per-app volume is something people change in the moment, not from a settings window. It would reuse `AppAudioRow` unchanged, add one `NSStatusItem` created only while App Volume is on, and follow the status-item rules in `KeepAwakeController` (right-click monitor, autosave name `dev.anode.appaudio`).

- [ ] **Step 1: Ask the owner** whether they want it, and whether it should sit beside the Menu Bar Hider's controls. Write a short plan then.
