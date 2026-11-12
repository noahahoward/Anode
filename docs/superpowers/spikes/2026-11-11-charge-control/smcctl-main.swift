import Foundation
// Plan 0 root probe. ALLOWLIST: key CHIE only, values 0x00 (adapter on) and 0x08 (adapter cut).
//   smcctl read | smcctl cut <seconds 1-120> | smcctl uncut
// `cut` restores 0x00 itself after <seconds>, and on SIGINT/SIGTERM. SIGKILL can't be caught: that is the test.
guard let smc = SMC() else { print("no AppleSMC"); exit(1) }
func chie() -> String { smc.rawInfo("CHIE").map { $0.bytes.map { String(format: "%02x", $0) }.joined() } ?? "ERR" }
func ext() -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg"); p.arguments = ["-rn", "AppleSmartBattery"]
    let pipe = Pipe(); p.standardOutput = pipe; try? p.run(); p.waitUntilExit()
    let s = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return s.components(separatedBy: "\n").first { $0.contains("\"ExternalConnected\"") }?.trimmingCharacters(in: .whitespaces) ?? "?"
}
let a = CommandLine.arguments
func stamp(_ m: String) { print("\(Date()) uid=\(getuid()) \(m) CHIE=\(chie()) \(ext())"); fflush(stdout) }
switch a.count > 1 ? a[1] : "" {
case "read": stamp("read")
case "uncut":
    let ok = smc.writeByte("CHIE", 0x00); stamp("uncut ok=\(ok) rc=0x\(String(UInt32(bitPattern: smc.lastError), radix: 16))")
case "cut":
    guard a.count > 2, let n = UInt32(a[2]), (1...120).contains(n) else { print("cut <1-120>"); exit(1) }
    for s in [SIGINT, SIGTERM, SIGHUP] { signal(s) { _ in _ = SMC()?.writeByte("CHIE", 0x00); exit(3) } }
    stamp("before")
    let ok = smc.writeByte("CHIE", 0x08)
    stamp("cut ok=\(ok) rc=0x\(String(UInt32(bitPattern: smc.lastError), radix: 16))")
    guard ok else { exit(2) }
    sleep(n)
    let back = smc.writeByte("CHIE", 0x00); sleep(2)
    stamp("restored ok=\(back)")
default: print("read | cut <seconds> | uncut"); exit(1)
}
