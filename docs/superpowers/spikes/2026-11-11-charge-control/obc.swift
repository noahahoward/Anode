import Foundation
import ObjectiveC
// enableSmartCharging: / disableSmartCharging:  B24@0:8^@16  (Optimized Battery Charging)
guard dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_NOW) != nil,
      let cls = NSClassFromString("PowerUISmartChargeClient") as? NSObject.Type else { exit(1) }
typealias InitName = @convention(c) (AnyObject, Selector, NSString) -> AnyObject?
typealias Act = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>) -> Bool
let a = cls.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue()
let si = NSSelectorFromString("initWithClientName:")
let ini = unsafeBitCast(method_getImplementation(class_getInstanceMethod(object_getClass(a), si)!), to: InitName.self)
let c = ini(a, si, "dev.anode.chargeprobe")!
let name = CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "off" ? "disableSmartCharging:" : "enableSmartCharging:"
let s = NSSelectorFromString(name)
let f = unsafeBitCast(method_getImplementation(class_getInstanceMethod(object_getClass(c), s)!), to: Act.self)
var e: NSError?; print("\(name) -> \(f(c, s, &e))\(e.map { " err=\($0)" } ?? "")")
