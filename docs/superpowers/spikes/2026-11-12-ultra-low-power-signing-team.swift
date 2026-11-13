// THROWAWAY SPIKE, READ-ONLY: can a root-owned process's path and signing team be read without root?
import Foundation
import Security
func team(_ pid: pid_t) -> String {
    var code: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess, let code else { return "no code object" }
    var sc: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &sc) == errSecSuccess, let sc else { return "no static code" }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(sc, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess, let d = info as? [String: Any] else { return "no signing info" }
    return "team=\(d[kSecCodeInfoTeamIdentifier as String] as? String ?? "-") id=\(d[kSecCodeInfoIdentifier as String] as? String ?? "-")"
}
var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
var size = 0
sysctl(&mib, 4, nil, &size, nil, 0)
var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
sysctl(&mib, 4, &procs, &size, nil, 0)
let n = size / MemoryLayout<kinfo_proc>.stride
let others = procs.prefix(n).filter { $0.kp_eproc.e_ucred.cr_uid != getuid() }
print("sysctl lists", n, "processes;", others.count, "not mine")
var readable = 0
for p in others {
    var buf = [CChar](repeating: 0, count: 4096)
    let path = proc_pidpath(p.kp_proc.p_pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
    if !path.isEmpty { readable += 1 }
    if !path.isEmpty, !["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"].contains(where: { path.hasPrefix($0) }) {
        print(" uid", p.kp_eproc.e_ucred.cr_uid, "pid", p.kp_proc.p_pid, "ppid", p.kp_eproc.e_ppid, (path as NSString).lastPathComponent, "|", team(p.kp_proc.p_pid))
    }
}
print("paths readable for", readable, "of", others.count)
for a in CommandLine.arguments.dropFirst() { if let pid = pid_t(a) { print("mine pid", pid, team(pid)) } }
