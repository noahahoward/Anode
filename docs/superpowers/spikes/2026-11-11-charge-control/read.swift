import Foundation
import ObjectiveC
// GETTERS ONLY. Signatures from the runtime's type encodings (powerui-enumerate.txt) and from
// pmset's call site (IOPSCopyBatteryLevelLimits: no arguments, returns a CF object to release).
// No setter selector appears anywhere in this file.
typealias CopyLimits = @convention(c) () -> Unmanaged<CFTypeRef>?
if let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
   let s = dlsym(h, "IOPSCopyBatteryLevelLimits") {
    let f = unsafeBitCast(s, to: CopyLimits.self)
    if let v = f()?.takeRetainedValue() { print("IOPSCopyBatteryLevelLimits: \(v)") } else { print("IOPSCopyBatteryLevelLimits: nil (no limits)") }
}
guard dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_NOW) != nil,
      let cls = NSClassFromString("PowerUISmartChargeClient") as? NSObject.Type else { print("no client class"); exit(1) }
typealias InitName = @convention(c) (AnyObject, Selector, NSString) -> AnyObject?
typealias GetB = @convention(c) (AnyObject, Selector) -> Bool
typealias GetQErr = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>) -> UInt64
typealias GetCErr = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>) -> UInt8
typealias GetObjErr = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>) -> AnyObject?
typealias OBC = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<ObjCBool>, UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<ObjCBool>, UnsafeMutablePointer<NSError?>) -> Bool
func imp<T>(_ o: AnyObject, _ name: String, _ t: T.Type) -> (Selector, T)? {
    let sel = NSSelectorFromString(name)
    guard let m = class_getInstanceMethod(object_getClass(o), sel) else { print("\(name): missing"); return nil }
    return (sel, unsafeBitCast(method_getImplementation(m), to: t))
}
let alloc = cls.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue()
guard let (si, ini) = imp(alloc, "initWithClientName:", InitName.self), let c = ini(alloc, si, "dev.anode.chargeprobe") else { print("init failed"); exit(1) }
for n in ["isMCLSupported", "isOBCSupported", "isDEoCSupported"] { if let (s, f) = imp(c, n, GetB.self) { print("\(n): \(f(c, s))") } }
for n in ["isMCLCurrentlyEnabled:", "currentChargeLimit:", "isSmartChargingCurrentlyEnabled:", "isDEoCCurrentlyEnabled:", "currentRecommendedChargeLimitWithError:"] {
    if let (s, f) = imp(c, n, GetQErr.self) { var e: NSError?; let v = f(c, s, &e); print("\(n) \(v)\(e.map { "  err=\($0)" } ?? "")") }
}
if let (s, f) = imp(c, "getMCLLimitWithError:", GetCErr.self) { var e: NSError?; let v = f(c, s, &e); print("getMCLLimitWithError: \(v)\(e.map { "  err=\($0)" } ?? "")") }
for n in ["availableChargeLimitsWithError:", "fullChargeDeadline:", "lastUsedLeewayWithError:"] {
    if let (s, f) = imp(c, n, GetObjErr.self) { var e: NSError?; let v = f(c, s, &e); print("\(n) \(v.map { "\($0)" } ?? "nil")\(e.map { "  err=\($0)" } ?? "")") }
}
if let (s, f) = imp(c, "isOBCEngaged:chargeLimit:chargingOverrideAllowed:withError:", OBC.self) {
    var eng = ObjCBool(false), lim: UInt64 = 0, ovr = ObjCBool(false); var e: NSError?
    let ok = f(c, s, &eng, &lim, &ovr, &e)
    print("isOBCEngaged:chargeLimit:… ok=\(ok) engaged=\(eng.boolValue) chargeLimit=\(lim) overrideAllowed=\(ovr.boolValue)\(e.map { "  err=\($0)" } ?? "")")
}
