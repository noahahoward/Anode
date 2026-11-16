import CoreAudio
import AudioToolbox
import Foundation
import IOKit.ps
import PowerKit

// ── The Mac's own readings for the Sound menu ───────────────────────────────
//
// Outputs, the output volume and mute, and the AirPods batteries: everything the Sound menu can read and set itself,
// with public calls and no permission. (The rows only macOS can drive go through `SystemPanelDriver`.)

protocol AudioOutputs: AnyObject {
    var devices: [OutputDevice] { get }
    var defaultDeviceID: String? { get }
    /// 0...1 on the default output; 0 when it has no volume control.
    var volume: Double { get }
    var muted: Bool { get }
    func setDefault(_ id: String)
    func setVolume(_ value: Double)
    func setMuted(_ muted: Bool)
    /// Called on the main queue when the list, the default output, the volume or the mute changed.
    var onChange: (() -> Void)? { get set }
    func start()
    func stop()
}

/// The accessory batteries (AirPods and their case) IOKit lists beside the Mac's own. `IOPSCopyPowerSourcesByType(0)` is how
/// they are reached; it is not in the public header, so it is looked up by name and its absence just means no readings.
func currentAccessoryBatteries() -> [AccessoryBattery] {
    typealias CopyByType = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOPSCopyPowerSourcesByType") else { return [] }
    guard let info = unsafeBitCast(symbol, to: CopyByType.self)(0)?.takeRetainedValue(),
          let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return [] }
    let descriptions = list.compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
    return AccessoryBattery.parse(descriptions)
}

final class CoreAudioOutputs: AudioOutputs {

    var onChange: (() -> Void)?
    private let system = AudioObjectID(kAudioObjectSystemObject)
    private var started = false
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var watchedDevice: AudioObjectID = 0

    // ── Reading ─────────────────────────────────────────────────────────────

    var devices: [OutputDevice] {
        let productID = currentAccessoryBatteries().first?.productID
        return outputIDs().compactMap { id -> OutputDevice? in
            guard let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
            let transport = Self.fourCC(value(id, kAudioDevicePropertyTransportType) ?? 0)
            return OutputDevice(id: uid, name: name, kind: OutputKind.guess(name: name, transport: transport,
                                                                           productID: transport == "blue" ? productID : nil))
        }
    }

    var defaultDeviceID: String? { defaultOutput().flatMap { string($0, kAudioDevicePropertyDeviceUID) } }

    var volume: Double {
        guard let d = defaultOutput() else { return 0 }
        var v: Float32 = 0
        return get(d, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput, into: &v) ? Double(v) : 0
    }

    var muted: Bool {
        guard let d = defaultOutput() else { return false }
        var m: UInt32 = 0
        return get(d, kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput, into: &m) && m != 0
    }

    // ── Setting ─────────────────────────────────────────────────────────────

    func setDefault(_ id: String) {
        guard let device = outputIDs().first(where: { string($0, kAudioDevicePropertyDeviceUID) == id }) else { return }
        var d = device
        var a = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectSetPropertyData(system, &a, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &d)
    }

    func setVolume(_ value: Double) {
        guard let d = defaultOutput() else { return }
        var v = Float32(min(1, max(0, value)))
        var a = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
        AudioObjectSetPropertyData(d, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
    }

    func setMuted(_ muted: Bool) {
        guard let d = defaultOutput() else { return }
        var m: UInt32 = muted ? 1 : 0
        var a = Self.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
        AudioObjectSetPropertyData(d, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
    }

    // ── Listening ───────────────────────────────────────────────────────────

    func start() {
        guard !started else { return }
        started = true
        listen(system, Self.address(kAudioHardwarePropertyDevices))
        listen(system, Self.address(kAudioHardwarePropertyDefaultOutputDevice), rewatch: true)
        watchDefaultDevice()
    }

    func stop() {
        guard started else { return }
        started = false
        for (object, address, block) in listeners {
            var a = address
            AudioObjectRemovePropertyListenerBlock(object, &a, DispatchQueue.main, block)
        }
        listeners.removeAll()
        watchedDevice = 0
    }

    private func listen(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, rewatch: Bool = false) {
        var a = address
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.started else { return }
            if rewatch { self.watchDefaultDevice() }
            self.onChange?()
        }
        if AudioObjectAddPropertyListenerBlock(object, &a, DispatchQueue.main, block) == noErr { listeners.append((object, address, block)) }
    }

    /// The volume and the mute belong to the default device, so they are watched on whichever one it is now.
    private func watchDefaultDevice() {
        guard let d = defaultOutput(), d != watchedDevice else { return }
        // Drop the listeners of the device it replaced.
        for (object, address, block) in listeners where object == watchedDevice && object != system {
            var a = address
            AudioObjectRemovePropertyListenerBlock(object, &a, DispatchQueue.main, block)
        }
        listeners.removeAll { $0.0 == watchedDevice && $0.0 != system }
        watchedDevice = d
        listen(d, Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput))
        listen(d, Self.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput))
    }

    // ── Core Audio helpers ──────────────────────────────────────────────────

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, into value: inout T) -> Bool {
        var a = Self.address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value) == noErr
    }

    private func value(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var v: UInt32 = 0
        return get(object, selector, into: &v) ? v : nil
    }

    private func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var s: Unmanaged<CFString>?
        var a = Self.address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, &s) == noErr, let s else { return nil }
        return s.takeRetainedValue() as String
    }

    private func defaultOutput() -> AudioObjectID? {
        var d: AudioObjectID = 0
        return get(system, kAudioHardwarePropertyDefaultOutputDevice, into: &d) && d != 0 ? d : nil
    }

    /// Devices with at least one output stream, hidden ones left out.
    private func outputIDs() -> [AudioObjectID] {
        var a = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { id in
            var streams = Self.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
            var n: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &n) == noErr, n > 0 else { return false }
            return (value(id, kAudioDevicePropertyIsHidden) ?? 0) == 0
        }
    }

    private static func fourCC(_ v: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xff) }, encoding: .ascii) ?? ""
    }
}
