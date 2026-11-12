import Foundation
import ObjectiveC
import MachO
// LIST ONLY. Loads PowerUI and prints classes and method signatures. Calls no method.
let path = "/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI"
guard dlopen(path, RTLD_NOW) != nil else { print("dlopen failed: \(String(cString: dlerror()))"); exit(1) }
var image = path
for i in 0..<_dyld_image_count() { let n = String(cString: _dyld_get_image_name(i)); if n.contains("PowerUI.framework") { image = n } }
print("# image \(image)")
var count: UInt32 = 0
guard let names = objc_copyClassNamesForImage(image, &count) else { print("no classes"); exit(1) }
var all: [String] = []
for i in 0..<Int(count) { all.append(String(cString: names[i])) }
print("# \(all.count) classes in PowerUI")
let interesting = all.filter { $0.range(of: "Charg|MCL|Limit|Battery|Smart", options: .regularExpression) != nil }.sorted()
print("# matching: \(interesting.joined(separator: ", "))")
func dump(_ cls: AnyClass, _ label: String) {
    var n: UInt32 = 0
    if let ms = class_copyMethodList(cls, &n) {
        var out: [String] = []
        for i in 0..<Int(n) {
            let m = ms[i]
            let enc = method_getTypeEncoding(m).map { String(cString: $0) } ?? "?"
            out.append("  \(label) \(NSStringFromSelector(method_getName(m)))  [\(enc)]")
        }
        out.sorted().forEach { print($0) }
        free(ms)
    }
}
for name in interesting {
    guard let cls = objc_getClass(name) as? AnyClass else { continue }
    print("== \(name)")
    dump(cls, "-")
    if let meta = object_getClass(cls) { dump(meta, "+") }
}
