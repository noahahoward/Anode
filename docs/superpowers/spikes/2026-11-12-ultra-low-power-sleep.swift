// THROWAWAY SPIKE, gate step 5: a stopped app across a sleep. Stops one blank text document, sleeps the Mac, continues it after wake.
import AppKit
let ws = NSWorkspace.shared
let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("anode-ulp-sleep.txt")
try? "probe".write(to: scratch, atomically: true, encoding: .utf8)
let prev = ws.frontmostApplication
var target: NSRunningApplication?
func wait(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
func windows(_ pid: pid_t) -> Int {
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    return list.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }.count
}
atexit { if let t = target { kill(t.processIdentifier, SIGCONT) } }
let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true
ws.open([scratch], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"), configuration: cfg) { app, _ in target = app }
wait(3)
guard let app = target ?? NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first else { print("could not open the document app"); exit(2) }
target = app
let pid = app.processIdentifier
prev?.activate(options: []); wait(1)
kill(pid, SIGSTOP); wait(1)
print("stopped; windows", windows(pid), "- sleeping now")
let p = Process(); p.launchPath = "/usr/bin/pmset"; p.arguments = ["sleepnow"]; try? p.run()
var last = Date(), slept = 0.0
let deadline = Date().addingTimeInterval(300)
while Date() < deadline {
    wait(1)
    let gap = Date().timeIntervalSince(last) - 1
    last = Date()
    if gap > 6 { slept = gap; break }
}
if slept == 0 { print("the Mac did not sleep within 5 minutes") } else { print(String(format: "woke after about %.0f s asleep", slept)) }
wait(4)
var info = proc_bsdinfo()
let alive = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0
print("before continue: alive", alive, "status", info.pbi_status, "(4 = stopped) windows", windows(pid), "terminated", app.isTerminated)
kill(pid, SIGCONT); wait(2)
app.activate(options: []); wait(1.5)
print("after continue: frontmost", ws.frontmostApplication?.bundleIdentifier ?? "?", "windows", windows(pid), "terminated", app.isTerminated)
app.terminate(); wait(1); if !app.isTerminated { app.forceTerminate() }
target = nil
prev?.activate(options: []); wait(0.5)
try? FileManager.default.removeItem(at: scratch)
print("done")
