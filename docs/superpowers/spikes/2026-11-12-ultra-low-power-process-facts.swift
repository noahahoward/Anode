// THROWAWAY SPIKE, READ-ONLY: how processes belong to apps; who owns event taps; who holds audio input.
import AppKit
import CoreAudio
import Darwin
typealias RespFn = @convention(c) (pid_t) -> pid_t
let resp: RespFn? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid").map { unsafeBitCast($0, to: RespFn.self) }
print("responsibility symbol:", resp != nil)
struct P { var pid: pid_t; var ppid: pid_t; var uid: uid_t; var path: String; var resp: pid_t; var kind: String; var bundle: String?; var name: String }
var pids = [pid_t](repeating: 0, count: 8192)
let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
var all: [pid_t: P] = [:]
for pid in pids.prefix(n) where pid > 0 {
    var info = proc_bsdinfo()
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { continue }
    var buf = [CChar](repeating: 0, count: 4096)
    let path = proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
    let app = NSRunningApplication(processIdentifier: pid)
    let kind = app.map { $0.activationPolicy == .regular ? "regular" : ($0.activationPolicy == .accessory ? "accessory" : "none") } ?? "none"
    all[pid] = P(pid: pid, ppid: pid_t(info.pbi_ppid), uid: info.pbi_uid, path: path, resp: resp?(pid) ?? pid, kind: kind,
                 bundle: app?.bundleIdentifier, name: app?.localizedName ?? (path as NSString).lastPathComponent)
}
let me = getuid()
let mine = all.values.filter { $0.uid == me }
print("processes:", all.count, "mine:", mine.count)
func isSysPath(_ p: String) -> Bool { ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"].contains { p.hasPrefix($0) } }
func ownerByResp(_ p: P) -> P { all[p.resp] ?? p }
func ownerByParents(_ p: P) -> P { var c = p; var hops = 0
    while hops < 40, c.kind == "none", c.ppid > 1, let up = all[c.ppid] { c = up; hops += 1 }
    return c }
func label(_ p: P) -> String { p.bundle ?? "exe:" + p.name }
// 1. groups by responsible
var groups: [String: [P]] = [:]
for p in mine { groups[label(ownerByResp(p)), default: []].append(p) }
print("\n== groups by responsible process (mine), owners that are not system paths or are apps:")
for (k, v) in groups.sorted(by: { $0.value.count > $1.value.count }) {
    let o = ownerByResp(v[0])
    if isSysPath(o.path) && o.kind != "regular" { continue }
    let sys = v.filter { isSysPath($0.path) }.count
    print(String(format: "%3d procs (%2d in system paths) %@ [%@]", v.count, sys, k, o.kind), "e.g.", Set(v.map { ($0.path as NSString).lastPathComponent }).sorted().prefix(5).joined(separator: ", "))
}
// 2. disagreements: responsible says one app, parent chain says another
var dis: [String: Int] = [:]
for p in mine { let a = label(ownerByResp(p)), b = label(ownerByParents(p)); if a != b { dis["resp=\(a)  parents=\(b)", default: 0] += 1 } }
print("\n== responsible vs parent chain disagree (count  pair), top 25:")
for (k, v) in dis.sorted(by: { $0.value > $1.value }).prefix(25) { print(String(format: "%3d", v), k) }
// 3. system-path processes whose responsible is a non-system app
print("\n== system-located processes attributed to an app (count by app  examples):")
var sysAttr: [String: Set<String>] = [:]; var sysCount: [String: Int] = [:]
for p in mine where isSysPath(p.path) { let o = ownerByResp(p); if o.pid != p.pid, !(isSysPath(o.path) && o.kind != "regular") { sysAttr[label(o), default: []].insert((p.path as NSString).lastPathComponent); sysCount[label(o), default: 0] += 1 } }
for (k, v) in sysAttr.sorted(by: { sysCount[$0.key]! > sysCount[$1.key]! }) { print(String(format: "%3d", sysCount[k]!), k, "→", v.sorted().prefix(6).joined(separator: ", ")) }
// 4. event tap owners
var count: UInt32 = 0
CGGetEventTapList(0, nil, &count)
var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
CGGetEventTapList(count, &taps, &count)
print("\n== event taps:", count)
for t in taps.prefix(Int(count)) { let p = all[t.tappingProcess]; print("  pid", t.tappingProcess, p.map(label) ?? "?", "enabled", t.enabled, "listenOnly", t.options == .listenOnly, "tapPoint", t.tapPoint.rawValue) }
// 5. audio input holders (macOS 14+)
if #available(macOS 14.0, *) {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    var objs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &objs)
    print("\n== audio process objects:", objs.count)
    for o in objs {
        var pid: pid_t = 0; var s = UInt32(MemoryLayout<pid_t>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(o, &a, 0, nil, &s, &pid)
        var inp: UInt32 = 0, out: UInt32 = 0; s = 4
        a.mSelector = kAudioProcessPropertyIsRunningInput; AudioObjectGetPropertyData(o, &a, 0, nil, &s, &inp)
        a.mSelector = kAudioProcessPropertyIsRunningOutput; s = 4; AudioObjectGetPropertyData(o, &a, 0, nil, &s, &out)
        if inp != 0 || out != 0 { print("  pid", pid, all[pid].map { label(ownerByResp($0)) } ?? "?", "input", inp, "output", out) }
    }
}
