// click x y [left|right]  — a real HID-level click, which is the only kind a
// macOS 27 status item (hosted by MenuBarAgent) actually receives.
import CoreGraphics
import Foundation
let a = CommandLine.arguments
let p = CGPoint(x: Double(a[1])!, y: Double(a[2])!)
let right = a.count > 3 && a[3] == "right"
let (dn, up, btn): (CGEventType, CGEventType, CGMouseButton) =
    right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: btn)?.post(tap: .cghidEventTap)
usleep(60_000)
CGEvent(mouseEventSource: nil, mouseType: dn, mouseCursorPosition: p, mouseButton: btn)?.post(tap: .cghidEventTap)
usleep(UInt32(ProcessInfo.processInfo.environment["HOLD_MS"].flatMap { UInt32($0) } ?? 120) * 1000)
CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: p, mouseButton: btn)?.post(tap: .cghidEventTap)
