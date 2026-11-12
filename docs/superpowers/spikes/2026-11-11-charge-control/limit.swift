import Foundation
import ObjectiveC
// Plan 0 probe: set / disable Apple's charge limit (MCL) via PowerUISmartChargeClient.
// Usage: limit set <n> | limit enable | limit disable | limit tempcharge
// Signatures from the runtime type encodings (powerui-enumerate.txt):
//   setMCLLimit:error:  B28@0:8C16^@20   enableMCL:/disableMCL:/temporarilyEnableCharging:  B24@0:8^@16
guard dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_NOW) != nil,
      let cls = NSClassFromString("PowerUISmartChargeClient") as? NSObject.Type else { print("no client"); exit(1) }
typealias InitName = @convention(c) (AnyObject, Selector, NSString) -> AnyObject?
typealias SetU8 = @convention(c) (AnyObject, Selector, UInt8, UnsafeMutablePointer<NSError?>) -> Bool
typealias Act = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>) -> Bool
func imp<T>(_ o: AnyObject, _ n: String, _ t: T.Type) -> (Selector, T) {
    let s = NSSelectorFromString(n)
    guard let m = class_getInstanceMethod(object_getClass(o), s) else { print("missing \(n)"); exit(2) }
    return (s, unsafeBitCast(method_getImplementation(m), to: t))
}
let a = cls.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue()
let (si, ini) = imp(a, "initWithClientName:", InitName.self)
guard let c = ini(a, si, "dev.anode.chargeprobe") else { print("init failed"); exit(1) }
let args = CommandLine.arguments
var e: NSError?
switch args.count > 1 ? args[1] : "" {
case "set":
    guard args.count > 2, let n = UInt8(args[2]), n <= 100 else { print("set <0-100>"); exit(1) }
    let (s, f) = imp(c, "setMCLLimit:error:", SetU8.self); let ok = f(c, s, n, &e)
    print("setMCLLimit:\(n) -> \(ok)\(e.map { " err=\($0)" } ?? "")")
case "enable", "disable", "tempcharge":
    let sel = ["enable": "enableMCL:", "disable": "disableMCL:", "tempcharge": "temporarilyEnableCharging:"][args[1]]!
    let (s, f) = imp(c, sel, Act.self); let ok = f(c, s, &e)
    print("\(sel) -> \(ok)\(e.map { " err=\($0)" } ?? "")")
default: print("usage: set <n> | enable | disable | tempcharge"); exit(1)
}
