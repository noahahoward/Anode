// THROWAWAY SPIKE, gate step 6: hold the brightness ceiling at 0.5 for N seconds; log every time it had to be pulled back.
import Foundation
import CoreGraphics
typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
typealias SetFn = @convention(c) (UInt32, Float) -> Int32
guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
      let g = dlsym(h, "DisplayServicesGetBrightness"), let s = dlsym(h, "DisplayServicesSetBrightness") else { print("no DisplayServices"); exit(2) }
let get = unsafeBitCast(g, to: GetFn.self), set = unsafeBitCast(s, to: SetFn.self)
let d = CGMainDisplayID()
func now() -> Float { var v: Float = -1; _ = get(d, &v); return v }
let secs = Double(CommandLine.arguments.dropFirst().first ?? "120") ?? 120
let original = now()
let t0 = Date()
var pulls = 0, above: Date? = nil, peak: Float = 0, longest = 0.0, lows: Set<String> = []
while Date().timeIntervalSince(t0) < secs {
    let v = now()
    if v > 0.51 {
        if above == nil { above = Date(); peak = v; pulls += 1 }
        peak = max(peak, v)
        _ = set(d, 0.5)
    } else if let a = above {
        let dur = Date().timeIntervalSince(a)
        longest = max(longest, dur)
        print(String(format: "+%5.1fs above the ceiling for %.2f s, peak %.3f", a.timeIntervalSince(t0), dur, peak))
        above = nil
    }
    lows.insert(String(format: "%.2f", v))
    Thread.sleep(forTimeInterval: 0.05)
}
_ = set(d, original)
print(String(format: "pulled back %d times, longest excursion %.2f s, levels seen %@, restored to %.3f (now %.3f)", pulls, longest, lows.sorted().joined(separator: " "), original, now()))
