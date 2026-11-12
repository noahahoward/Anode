import Foundation
// READ-ONLY full SMC dump. The SMC copy beside this file has no write command at all.
// One line per key, sorted: name type size attrs value | ERR(rc)
guard let smc = SMC() else { print("could not open AppleSMC"); exit(1) }
let n = smc.keyCount()
var lines: [String] = []
for i in 0..<n {
    guard let k = smc.key(at: i), !k.isEmpty else { lines.append("?idx\(i) ERR(index rc=0x\(String(UInt32(bitPattern: smc.lastError), radix: 16)))"); continue }
    if let r = smc.rawInfo(k) {
        let hex = r.bytes.map { String(format: "%02x", $0) }.joined()
        lines.append(String(format: "%@ %@ %d 0x%02x %@", k, r.type.isEmpty ? "-" : r.type, r.size, r.attrs, hex.isEmpty ? "-" : hex))
    } else {
        lines.append("\(k) ERR(rc=0x\(String(UInt32(bitPattern: smc.lastError), radix: 16)))")
    }
}
print("# keys=\(n) uid=\(getuid())")
for l in lines.sorted() { print(l) }
