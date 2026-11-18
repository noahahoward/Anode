// A small driver for `Tests/installer-tests.sh --full`: it presses things in the TEST COPY of Anode (see AppSandbox) through
// Accessibility, by title, and nothing else. No synthetic mouse clicks and no key presses: AXPress on a button or a menu
// item, which is what VoiceOver does, so it cannot land on whatever happens to be under the pointer, and a window that is not
// there is simply not found. It is compiled by the test (swiftc) and run with the process id of the copy it was started for;
// it is never given the person's own Anode, which the test does not name to it.
//
//   anode-ui trusted                          exit 0 if this process may use Accessibility, else 3 (never asks)
//   anode-ui window PID TITLE SECONDS         wait for a window titled TITLE
//   anode-ui menu PID TOP ITEM                press ITEM in the menu bar's TOP menu
//   anode-ui press PID TITLE SECONDS          wait for a button titled TITLE (exactly), then press it
//   anode-ui list PID                         what is on screen, for the diagnosis
//
// Exit status: 0 done, 1 not found in time, 2 wrong use, 3 Accessibility is not granted to the process that runs this.
import ApplicationServices
import Foundation

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value as AnyObject? : nil
}
func text(_ e: AXUIElement, _ name: String) -> String { (attr(e, name) as? String) ?? "" }
func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func titleOf(_ e: AXUIElement) -> String {
    let t = text(e, kAXTitleAttribute)
    return t.isEmpty ? text(e, kAXDescriptionAttribute) : t
}

/// Every element under `e` (depth first), `e` included.
func walk(_ e: AXUIElement, depth: Int = 0, _ visit: (AXUIElement, Int) -> Void) {
    visit(e, depth)
    if depth > 30 { return }
    for c in children(e) { walk(c, depth: depth + 1, visit) }
}

func windows(_ app: AXUIElement) -> [AXUIElement] { (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] }

func waitFor(_ seconds: Double, _ found: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    repeat {
        if found() { return true }
        Thread.sleep(forTimeInterval: 0.25)
    } while Date() < end
    return false
}

/// The first element with this role and exactly this title anywhere in the app's windows (sheets and alerts included).
func find(_ app: AXUIElement, role: String, title: String) -> AXUIElement? {
    for w in windows(app) {
        var hit: AXUIElement?
        walk(w) { e, _ in
            if hit == nil, text(e, kAXRoleAttribute) == role, titleOf(e) == title { hit = e }
        }
        if let hit { return hit }
    }
    return nil
}

let args = CommandLine.arguments
guard args.count >= 2 else { FileHandle.standardError.write(Data("usage: anode-ui trusted|window|menu|press|list …\n".utf8)); exit(2) }

if args[1] == "trusted" { exit(AXIsProcessTrusted() ? 0 : 3) }
guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("Accessibility is not granted to the program running this test (System Settings › Privacy & Security › Accessibility).\n".utf8))
    exit(3)
}
guard args.count >= 3, let pid = pid_t(args[2]) else { FileHandle.standardError.write(Data("a process id is needed\n".utf8)); exit(2) }
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 3)

switch args[1] {
case "window":
    guard args.count >= 5, let seconds = Double(args[4]) else { exit(2) }
    exit(waitFor(seconds) { windows(app).contains { titleOf($0) == args[3] } } ? 0 : 1)

case "menu":
    guard args.count >= 5 else { exit(2) }
    var item: AXUIElement?
    _ = waitFor(20) {
        guard let bar = attr(app, kAXMenuBarAttribute) else { return false }
        for top in children(bar as! AXUIElement) where titleOf(top) == args[3] {
            walk(top) { e, _ in
                if item == nil, text(e, kAXRoleAttribute) == kAXMenuItemRole, titleOf(e) == args[4] { item = e }
            }
        }
        return item != nil
    }
    guard let item else { FileHandle.standardError.write(Data("no menu item \(args[3]) › \(args[4])\n".utf8)); exit(1) }
    exit(AXUIElementPerformAction(item, kAXPressAction as CFString) == .success ? 0 : 1)

case "press":
    guard args.count >= 5, let seconds = Double(args[4]) else { exit(2) }
    var button: AXUIElement?
    _ = waitFor(seconds) { button = find(app, role: kAXButtonRole as String, title: args[3]); return button != nil }
    guard let button else { FileHandle.standardError.write(Data("no button titled “\(args[3])”\n".utf8)); exit(1) }
    let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
    // A button that opens a modal alert does not return until the alert is gone (the action runs the alert's own loop): the
    // call times out, which here means it was pressed.
    if result == .success || result == .cannotComplete { exit(0) }
    FileHandle.standardError.write(Data("pressing “\(args[3])” failed: \(result.rawValue)\n".utf8))
    exit(1)

case "list":
    for w in windows(app) {
        print("window “\(titleOf(w))”")
        walk(w) { e, depth in
            let role = text(e, kAXRoleAttribute)
            if role == kAXButtonRole as String || role == kAXCheckBoxRole as String || role == kAXMenuItemRole as String {
                print(String(repeating: "  ", count: min(depth, 6) + 1) + "\(role) “\(titleOf(e))”")
            }
        }
    }
    exit(0)

default:
    exit(2)
}
