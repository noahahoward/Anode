import Foundation
import CoreAudio
import AudioToolbox
import AppKit

setbuf(stdout, nil)
let t0 = Date()
func log(_ s: String) { print(String(format: "[%6.2f] ", Date().timeIntervalSince(t0)) + s) }

// ── Core Audio property helpers ──
func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func getU32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
    var a = addr(sel, scope); var v: UInt32 = 0; var sz = UInt32(4)
    return AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, &v) == 0 ? v : nil
}
func getString(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var a = addr(sel); var v: Unmanaged<CFString>?; var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let st = AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, &v)
    return st == 0 ? v?.takeRetainedValue() as String? : nil
}
func getIDs(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> [AudioObjectID] {
    var a = addr(sel); var sz = UInt32(0)
    guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &sz) == 0, sz > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(sz) / 4)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, &ids) == 0 else { return [] }
    return ids
}
func getF64(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> Double? {
    var a = addr(sel, scope); var v = Float64(0); var sz = UInt32(8)
    return AudioObjectGetPropertyData(obj, &a, 0, nil, &sz, &v) == 0 ? v : nil
}

struct Proc { let obj: AudioObjectID; let pid: Int32; let bundle: String; let running: Bool; let runningOutput: Bool }
func processes() -> [Proc] {
    getIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).map { o in
        Proc(obj: o, pid: Int32(getU32(o, kAudioProcessPropertyPID) ?? 0), bundle: getString(o, kAudioProcessPropertyBundleID) ?? "",
             running: (getU32(o, kAudioProcessPropertyIsRunning) ?? 0) != 0, runningOutput: (getU32(o, kAudioProcessPropertyIsRunningOutput) ?? 0) != 0)
    }
}
func defaultOutput() -> AudioObjectID { getU32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) ?? 0 }
func exe(_ pid: Int32) -> String {
    var buf = [CChar](repeating: 0, count: 4096); let n = proc_pidpath(pid, &buf, 4096)
    return n > 0 ? String(cString: buf) : "?"
}
func appRoot(_ path: String) -> String { // outermost .app
    if let r = path.range(of: ".app/") { return String(path[..<r.lowerBound]) + ".app" }
    return path
}

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "list"

if mode == "preflight" {
    typealias PF = @convention(c) (CFString, CFDictionary?) -> Int32
    if let h = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_NOW), let f = dlsym(h, "TCCAccessPreflight") {
        let fn = unsafeBitCast(f, to: PF.self)
        for svc in ["kTCCServiceAudioCapture", "kTCCServiceScreenCapture", "kTCCServiceMicrophone"] { print("TCCAccessPreflight(\(svc)) = \(fn(svc as CFString, nil))   (0 granted, 1 denied, 2 undetermined)") }
    } else { print("TCCAccessPreflight not found") }
    exit(0)
}
if mode == "appear" {
    // spawn a quiet afplay and time how long until Core Audio lists its process object and it reports output
    let known = Set(processes().map { $0.pid })
    let t = Date(); let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay"); p.arguments = ["-t", "4", CommandLine.arguments[2]]
    try! p.run()
    var listed: Double?, outAt: Double?
    while Date().timeIntervalSince(t) < 3 {
        if let me = processes().first(where: { $0.pid == p.processIdentifier && !known.contains($0.pid) }) {
            if listed == nil { listed = Date().timeIntervalSince(t) * 1000 }
            if me.runningOutput { outAt = Date().timeIntervalSince(t) * 1000; break }
        }
        usleep(2000)
    }
    print(String(format: "spawn -> process object listed after %.0f ms; reports IsRunningOutput after %.0f ms", listed ?? -1, outAt ?? -1))
    p.terminate(); exit(0)
}
if mode == "devices" {
    for d in getIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices) { print("dev \(d) \(getString(d, kAudioObjectPropertyName) ?? "?") uid=\(getString(d, kAudioDevicePropertyDeviceUID) ?? "?")") }
    exit(0)
}
if mode == "list" {
    for p in processes() {
        let path = exe(p.pid)
        print(String(format: "obj=%-5d pid=%-6d out=%d run=%d  %@  [%@]", p.obj, p.pid, p.runningOutput ? 1 : 0, p.running ? 1 : 0, p.bundle, appRoot(path)))
    }
    exit(0)
}

// ── tap: aggregate + IO proc with gain ──
// usage: aprobe tap <appPathSubstring> <seconds> <gain0> [gain1 at half time]
let needle = args[2]; let secs = Double(args[3]) ?? 10
let gains = args.dropFirst(4).compactMap { Float($0) }
let outDev = defaultOutput()
let outUID = getString(outDev, kAudioDevicePropertyDeviceUID) ?? "?"
log("default output device \(outDev) uid=\(outUID) rate=\(getF64(outDev, kAudioDevicePropertyNominalSampleRate) ?? 0)")
let all = processes()
let mine = all.filter { appRoot(exe($0.pid)).contains(needle) }
log("processes of '\(needle)': " + mine.map { "\($0.pid)(\($0.runningOutput ? "OUT" : "-"))" }.joined(separator: " "))
guard !mine.isEmpty else { log("no matching audio processes"); exit(2) }

guard #available(macOS 14.2, *) else { exit(3) }
let desc = CATapDescription(stereoMixdownOfProcesses: mine.map { $0.obj })
desc.name = "anode-spike"
desc.isPrivate = true
desc.muteBehavior = .muted
var tapID = AudioObjectID(kAudioObjectUnknown)
let tapStart = Date()
var st = AudioHardwareCreateProcessTap(desc, &tapID)
log("AudioHardwareCreateProcessTap status=\(st) tapID=\(tapID) (\(String(format: "%.0f", Date().timeIntervalSince(tapStart) * 1000)) ms)")
guard st == 0 else { exit(4) }

var fmtA = addr(kAudioTapPropertyFormat); var asbd = AudioStreamBasicDescription(); var asz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
AudioObjectGetPropertyData(tapID, &fmtA, 0, nil, &asz, &asbd)
log("tap format: rate=\(asbd.mSampleRate) channels=\(asbd.mChannelsPerFrame) flags=\(asbd.mFormatFlags) interleaved=\((asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0) bytes/frame=\(asbd.mBytesPerFrame) bits=\(asbd.mBitsPerChannel)")
let tapUID = desc.uuid.uuidString

let aggUID = UUID().uuidString
let dict: [String: Any] = [
    kAudioAggregateDeviceNameKey: "anode-spike-agg",
    kAudioAggregateDeviceUIDKey: aggUID,
    kAudioAggregateDeviceMainSubDeviceKey: outUID,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
    kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUID]],
]
var aggID = AudioObjectID(kAudioObjectUnknown)
st = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggID)
log("AudioHardwareCreateAggregateDevice status=\(st) aggID=\(aggID)")
guard st == 0 else { AudioHardwareDestroyProcessTap(tapID); exit(5) }

func latencyMs(_ dev: AudioObjectID, _ scope: AudioObjectPropertyScope) -> String {
    let lat = getU32(dev, kAudioDevicePropertyLatency, scope) ?? 0
    let safe = getU32(dev, kAudioDevicePropertySafetyOffset, scope) ?? 0
    let buf = getU32(dev, kAudioDevicePropertyBufferFrameSize, scope) ?? 0
    let rate = getF64(dev, kAudioDevicePropertyNominalSampleRate) ?? 48000
    let total = Double(lat + safe + buf)
    return String(format: "latency=%d safety=%d buffer=%d => %.1f ms @%.0f Hz", lat, safe, buf, total / rate * 1000, rate)
}
log("plain output  out: \(latencyMs(outDev, kAudioObjectPropertyScopeOutput))")
log("aggregate     out: \(latencyMs(aggID, kAudioObjectPropertyScopeOutput))")
log("aggregate      in: \(latencyMs(aggID, kAudioObjectPropertyScopeInput))")

// Shared with the IO callback: plain floats (probe only; the product code will use its own lock-free design)
var firstCall: Date?
final class Shared { var first = false; var gain: Float = 1; var inPeak: Float = 0; var outPeak: Float = 0; var calls = 0; var inBuffers = 0; var outBuffers = 0; var frames: UInt32 = 0; var silentCalls = 0 }
let sh = Shared(); sh.gain = gains.first ?? 0.5
var procID: AudioDeviceIOProcID?
let q = DispatchQueue(label: "io", qos: .userInteractive)
let tIO = Date()
st = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, q) { _, inData, _, outData, _ in
    let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
    let outList = UnsafeMutableAudioBufferListPointer(outData)
    if sh.calls == 0 && !sh.first { sh.first = true; firstCall = Date() }
    sh.calls += 1; sh.inBuffers = inList.count; sh.outBuffers = outList.count
    var ipk: Float = 0, opk: Float = 0
    for (i, ob) in outList.enumerated() {
        guard let od = ob.mData?.assumingMemoryBound(to: Float.self) else { continue }
        let on = Int(ob.mDataByteSize) / 4
        if i < inList.count, let id = inList[i].mData?.assumingMemoryBound(to: Float.self) {
            let n = min(on, Int(inList[i].mDataByteSize) / 4)
            let g = sh.gain
            for k in 0..<n { let x = id[k]; ipk = max(ipk, abs(x)); let y = max(-1, min(1, x * g)); od[k] = y; opk = max(opk, abs(y)) }
            if n < on { for k in n..<on { od[k] = 0 } }
            if i == 0 { sh.frames = UInt32(n) / max(1, asbd.mChannelsPerFrame) }
        } else { for k in 0..<on { od[k] = 0 } }
    }
    if ipk == 0 { sh.silentCalls += 1 }
    sh.inPeak = max(sh.inPeak, ipk); sh.outPeak = max(sh.outPeak, opk)
}
log("AudioDeviceCreateIOProcIDWithBlock status=\(st) took \(String(format: "%.0f", Date().timeIntervalSince(tIO) * 1000)) ms")
guard st == 0, let procID else { exit(6) }
let startT = Date()
let tS = Date()
st = AudioDeviceStart(aggID, procID)
log("AudioDeviceStart status=\(st) took \(String(format: "%.0f", Date().timeIntervalSince(tS) * 1000)) ms")

var elapsed = 0.0
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now() + 1, repeating: 1)
var tick = 0
timer.setEventHandler {
    tick += 1
    let stage = gains.count > 1 ? min(gains.count - 1, Int(Double(tick) / secs * Double(gains.count))) : 0
    sh.gain = gains.isEmpty ? 0.5 : gains[stage]
    if tick == 1, let fc = firstCall { log(String(format: "first IO callback %.0f ms after AudioDeviceStart", fc.timeIntervalSince(startT) * 1000)) }
    log(String(format: "gain=%.2f  inPeak=%.3f outPeak=%.3f  calls=%d (silent %d)  in/out buffers=%d/%d frames/call=%d", sh.gain, sh.inPeak, sh.outPeak, sh.calls, sh.silentCalls, sh.inBuffers, sh.outBuffers, sh.frames))
    sh.inPeak = 0; sh.outPeak = 0; sh.calls = 0; sh.silentCalls = 0
    if Double(tick) >= secs { shutdown() }
}
func shutdown() {
    AudioDeviceStop(aggID, procID)
    AudioDeviceDestroyIOProcID(aggID, procID)
    AudioHardwareDestroyAggregateDevice(aggID)
    AudioHardwareDestroyProcessTap(tapID)
    log("torn down"); exit(0)
}
timer.resume()
RunLoop.main.run()
