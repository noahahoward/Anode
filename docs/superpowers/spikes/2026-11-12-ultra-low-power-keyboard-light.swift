// THROWAWAY SPIKE: can the keyboard backlight be read and set without root? Sets 0 for 2 s, then puts the old level back.
import Foundation
guard let b = Bundle(path: "/System/Library/PrivateFrameworks/CoreBrightness.framework"), b.load(),
      let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { print("no KeyboardBrightnessClient"); exit(2) }
let c = cls.init()
typealias GetFn = @convention(c) (AnyObject, Selector, UInt64) -> Float
typealias SetFn = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
typealias BoolFn = @convention(c) (AnyObject, Selector, UInt64) -> Bool
let idsSel = NSSelectorFromString("copyKeyboardBacklightIDs")
guard c.responds(to: idsSel), let ids = c.perform(idsSel)?.takeRetainedValue() as? [NSNumber], let first = ids.first else { print("no keyboard backlight ids"); exit(3) }
let id = first.uint64Value
let getSel = NSSelectorFromString("brightnessForKeyboard:"), setSel = NSSelectorFromString("setBrightness:forKeyboard:")
let autoSel = NSSelectorFromString("isAutoBrightnessEnabledForKeyboard:")
guard c.responds(to: getSel), c.responds(to: setSel) else { print("selectors missing"); exit(4) }
let get = unsafeBitCast(c.method(for: getSel), to: GetFn.self), set = unsafeBitCast(c.method(for: setSel), to: SetFn.self)
let before = get(c, getSel, id)
var auto = "?"
if c.responds(to: autoSel) { auto = String(unsafeBitCast(c.method(for: autoSel), to: BoolFn.self)(c, autoSel, id)) }
print("ids", ids, "level before", before, "auto", auto)
if CommandLine.arguments.contains("--set") {
    print("set 0 ->", set(c, setSel, 0, id)); Thread.sleep(forTimeInterval: 2); print("level now", get(c, getSel, id))
    print("restore ->", set(c, setSel, before, id)); Thread.sleep(forTimeInterval: 0.5); print("level after", get(c, getSel, id))
}
