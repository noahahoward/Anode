// THROWAWAY SPIKE: bright get | bright set <0...1>   (DisplayServices, built-in display)
import Foundation
import CoreGraphics
typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
typealias SetFn = @convention(c) (UInt32, Float) -> Int32
guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
      let g = dlsym(h, "DisplayServicesGetBrightness"), let s = dlsym(h, "DisplayServicesSetBrightness") else { print("no DisplayServices"); exit(2) }
let get = unsafeBitCast(g, to: GetFn.self), set = unsafeBitCast(s, to: SetFn.self)
let d = CGMainDisplayID()
let a = CommandLine.arguments
if a.count >= 3, a[1] == "set", let v = Float(a[2]) { let r = set(d, max(0, min(1, v))); if r != 0 { print("set failed", r); exit(1) } }
var v: Float = -1
let r = get(d, &v)
print(r == 0 ? String(format: "%.4f", v) : "get failed \(r)")
