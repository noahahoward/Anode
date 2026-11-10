// THROWAWAY SPIKE: does a window at screenSaver level draw OVER other apps' status items? (3 seconds, then exits)
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let s = NSScreen.screens[0]
let frame = NSRect(x: 1108, y: s.frame.maxY - 30, width: 396, height: 30)
let w = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
w.level = .screenSaver
w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
w.backgroundColor = .black
w.isOpaque = true
w.hasShadow = false
w.ignoresMouseEvents = true      // spike only: never swallow a click while nobody is watching
w.orderFrontRegardless()
DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { exit(0) }
app.run()
