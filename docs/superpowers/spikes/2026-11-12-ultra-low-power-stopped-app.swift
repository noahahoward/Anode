// THROWAWAY SPIKE, gate steps 3 and 4: one blank text document. (4) how long after hide() may it be stopped with no window left?
// (3) is the activation of a stopped app reported? Everything is continued and the app is quit at the end.
import AppKit
let ws = NSWorkspace.shared
let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("anode-ulp-probe.txt")
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
print("== step 4: hide, wait d, stop")
for d in [0.0, 0.2, 0.5, 1.0] {
    app.unhide(); app.activate(options: []); wait(1.5)
    let before = windows(pid)
    app.hide(); wait(d)
    kill(pid, SIGSTOP); wait(1.0)
    print(String(format: "d=%.1f s: windows before %d, after stop %d, isHidden %@", d, before, windows(pid), String(app.isHidden)))
    kill(pid, SIGCONT); wait(0.8)
    print(String(format: "        after continue: windows %d, isHidden %@", windows(pid), String(app.isHidden)))
}
print("== step 3: bring a stopped app forward")
app.unhide(); wait(0.5); prev?.activate(options: []); wait(1.5)
var seen: [String] = []
let t0 = Date()
let token = ws.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
    let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    seen.append(String(format: "+%.2fs %@", Date().timeIntervalSince(t0), a?.bundleIdentifier ?? "?"))
}
kill(pid, SIGSTOP); wait(0.5)
let p = Process(); p.launchPath = "/usr/bin/open"; p.arguments = ["-a", "TextEdit"]; try? p.run()
wait(4)
print("while stopped: notifications", seen, "| frontmost:", ws.frontmostApplication?.bundleIdentifier ?? "?", "| isActive", app.isActive)
kill(pid, SIGCONT); wait(2)
print("after continue: notifications", seen, "| frontmost:", ws.frontmostApplication?.bundleIdentifier ?? "?")
ws.notificationCenter.removeObserver(token)
app.terminate(); wait(1); if !app.isTerminated { app.forceTerminate() }
target = nil
prev?.activate(options: []); wait(0.5)
try? FileManager.default.removeItem(at: scratch)
print("done; previous front app restored:", ws.frontmostApplication?.bundleIdentifier ?? "?")
