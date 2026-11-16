import Foundation
import CoreAudio
import AudioToolbox
import Darwin
import PowerKit

// ── The real backend: Core Audio process taps ───────────────────────────────
//
// Built from the measured spike of 2026-11-06 (docs/superpowers/plans/2026-11-05-per-app-audio.md, "Measured"): a private tap
// that mutes the app's own output, a private aggregate device whose output is the default output, and an IO block that passes the
// tap's sound through a `GainStage`. The tap hears 48 kHz stereo interleaved float. On macOS 26 and later a tap can name the app
// by bundle id and keep it when it restarts, so an app that is not running yet is held from its first sound.
//
// NOT VERIFIED ON HARDWARE for the bundle-id tap (`bundleTapsVerified`). Until it is, `canTapAppsNotYetRunning` is false and the
// feature is not offered, because a muted app would not be silent from its first sound, and a known bug does not ship.

final class CoreAudioAppBackend: AppAudioBackend {

    /// Set to true only after the bundle-id tap was measured to hold a muted app from its very first sound.
    static let bundleTapsVerified = false
    /// The feature is offered in Beta Features only when everything it needs was verified.
    static var isReleaseReady: Bool { bundleTapsVerified && ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)) }

    var onProcessesChanged: (() -> Void)?
    var onOutputChanged: (() -> Void)?
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init() {
        watch(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) { [weak self] in self?.onProcessesChanged?() }
        watch(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in self?.onOutputChanged?() }
    }

    deinit {
        for (id, address, block) in listeners {
            var a = address
            AudioObjectRemovePropertyListenerBlock(id, &a, .main, block)
        }
    }

    private func watch(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ handler: @escaping () -> Void) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr { listeners.append((object, address, block)) }
    }

    // ── Reading ─────────────────────────────────────────────────────────────

    var canTapAppsNotYetRunning: Bool {
        guard Self.bundleTapsVerified else { return false }
        if #available(macOS 26.0, *) { return true }
        return false
    }

    func processes() -> [AudioProcessInfo] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard let pid: pid_t = Self.value(id, kAudioProcessPropertyPID), pid > 0 else { return nil }
            var buffer = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
            let running: UInt32 = Self.value(id, kAudioProcessPropertyIsRunningOutput) ?? 0
            return AudioProcessInfo(objectID: id, pid: pid, executablePath: String(cString: buffer), isRunningOutput: running != 0)
        }
    }

    func defaultOutputUID() -> String? {
        guard let device: AudioObjectID = Self.value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice), device != 0 else { return nil }
        return Self.string(device, kAudioDevicePropertyDeviceUID)
    }

    /// `TCCAccessPreflight` says whether the question was answered and how: 0 yes, 1 no, 2 not asked. It is a private call, found
    /// by name; when it is missing the answer is "not asked", which never mutes an app.
    func permission() -> AudioCapturePermission {
        typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_LAZY),
              let symbol = dlsym(handle, "TCCAccessPreflight") else { return .undetermined }
        let preflight = unsafeBitCast(symbol, to: Preflight.self)
        switch preflight("kTCCServiceAudioCapture" as CFString, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .undetermined
        }
    }

    // ── Starting a tap ──────────────────────────────────────────────────────

    func start(bundleID: String, processObjectIDs: [UInt32], outputUID: String, muteOriginal: Bool, gain: GainStage,
               onFailure: @escaping () -> Void) throws -> AppAudioSessionHandle {
        guard #available(macOS 14.2, *) else { throw BackendError.unavailable }
        let description: CATapDescription
        if canTapAppsNotYetRunning, #available(macOS 26.0, *) {
            description = CATapDescription()
            description.bundleIDs = [bundleID]
            description.isMixdown = true
            description.isMono = false
            description.isProcessRestoreEnabled = true   // the app is held again when it quits and starts again
        } else {
            guard !processObjectIDs.isEmpty else { throw BackendError.appNotRunning }
            description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs.map { AudioObjectID($0) })
        }
        description.name = "Anode app volume"
        description.isPrivate = true
        description.muteBehavior = muteOriginal ? .muted : .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr, tap != kAudioObjectUnknown else { throw BackendError.tap }
        let session = CoreAudioSession(tap: tap, gain: gain, onFailure: onFailure)
        do {
            try session.build(tapUUID: description.uuid.uuidString, outputUID: outputUID)
        } catch {
            session.stop()
            throw error
        }
        return session
    }

    enum BackendError: Error { case unavailable, appNotRunning, tap, aggregate, format, ioProc, start }

    // ── Core Audio properties ───────────────────────────────────────────────

    fileprivate static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, raw) == noErr else { return nil }
        return raw.load(as: T.self)
    }

    fileprivate static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let v = value?.takeRetainedValue() else { return nil }
        return v as String
    }
}

/// One tap, its aggregate device and its IO block. Ends in the reverse order it was built, and only once.
final class CoreAudioSession: AppAudioSessionHandle {
    private var tap: AudioObjectID
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var started = false
    private var stopped = false
    private let gain: GainStage
    private let onFailure: () -> Void
    private var aliveBlock: AudioObjectPropertyListenerBlock?
    private let scratch: UnsafeMutablePointer<Float>
    private static let scratchFrames = 8192

    init(tap: AudioObjectID, gain: GainStage, onFailure: @escaping () -> Void) {
        self.tap = tap; self.gain = gain; self.onFailure = onFailure
        scratch = UnsafeMutablePointer<Float>.allocate(capacity: Self.scratchFrames * 2)
        scratch.initialize(repeating: 0, count: Self.scratchFrames * 2)
    }

    deinit { scratch.deallocate() }

    func build(tapUUID: String, outputUID: String) throws {
        let dictionary: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Anode app volume", kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID, kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false, kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUUID]],
        ]
        guard AudioHardwareCreateAggregateDevice(dictionary as CFDictionary, &aggregate) == noErr else { throw CoreAudioAppBackend.BackendError.aggregate }
        // The tap hears 48 kHz stereo interleaved float (measured); anything else is not something this gain stage can serve.
        guard let format: AudioStreamBasicDescription = CoreAudioAppBackend.value(tap, kAudioTapPropertyFormat),
              format.mChannelsPerFrame == 2, format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        else { throw CoreAudioAppBackend.BackendError.format }
        let gain = self.gain, scratch = self.scratch
        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, nil) { _, input, _, output, _ in
            let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            let outs = UnsafeMutableAudioBufferListPointer(output)
            guard ins.count > 0, outs.count > 0, let src = ins[0].mData, let dst = outs[0].mData else { return }
            let inChannels = max(1, Int(ins[0].mNumberChannels)), outChannels = max(1, Int(outs[0].mNumberChannels))
            let frames = min(Int(ins[0].mDataByteSize) / (4 * inChannels), Int(outs[0].mDataByteSize) / (4 * outChannels))
            guard inChannels == 2, frames > 0 else { return }
            let source = src.assumingMemoryBound(to: Float.self), target = dst.assumingMemoryBound(to: Float.self)
            if outChannels == 2 {
                gain.render(input: source, output: target, frames: frames)
            } else if frames <= CoreAudioSession.scratchFrames {
                // An output that is not stereo: the stereo result goes to its first two channels (or its one, averaged).
                gain.render(input: source, output: scratch, frames: frames)
                for f in 0..<frames {
                    for c in 0..<outChannels {
                        target[f * outChannels + c] = outChannels == 1 ? 0.5 * (scratch[f * 2] + scratch[f * 2 + 1]) : (c < 2 ? scratch[f * 2 + c] : 0)
                    }
                }
            }
        }
        guard status == noErr, ioProc != nil else { throw CoreAudioAppBackend.BackendError.ioProc }
        // If the output device goes away under it, say so: the router removes the session and shows why.
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, !self.stopped else { return }
            if let alive: UInt32 = CoreAudioAppBackend.value(self.aggregate, kAudioDevicePropertyDeviceIsAlive), alive == 0 { self.onFailure() }
        }
        if AudioObjectAddPropertyListenerBlock(aggregate, &address, .main, block) == noErr { aliveBlock = block }
        guard AudioDeviceStart(aggregate, ioProc) == noErr else { throw CoreAudioAppBackend.BackendError.start }
        started = true
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        if aggregate != kAudioObjectUnknown {
            if let block = aliveBlock {
                var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                AudioObjectRemovePropertyListenerBlock(aggregate, &address, .main, block)
            }
            if started, let ioProc { AudioDeviceStop(aggregate, ioProc) }
            if let ioProc { AudioDeviceDestroyIOProcID(aggregate, ioProc) }
            AudioHardwareDestroyAggregateDevice(aggregate)
            aggregate = AudioObjectID(kAudioObjectUnknown)
        }
        if tap != kAudioObjectUnknown {
            if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tap) }
            tap = AudioObjectID(kAudioObjectUnknown)
        }
    }
}
