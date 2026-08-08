import Foundation
import PowerKit

// BetterStatsHelper — the only part of this project that runs as root.
//
// It exists for exactly one reason: SMC writes require root, and fan control is
// an SMC write. Everything else in BetterStats is deliberately unprivileged.
//
// The whole privileged surface is two operations: set one fan to one speed, and
// stop controlling the fans. It is small enough to audit in one sitting, and
// that is the point — a root daemon you cannot read in full is a root daemon you
// cannot trust.
//
// SECURITY NOTE, stated plainly. Stats installs its helper with SMJobBless,
// which makes launchd verify a Developer ID signature before the helper is ever
// installed. That requires a paid Apple certificate. This helper is installed by
// an admin-authorised script instead, so THERE IS NO SIGNATURE CHECK AT INSTALL
// TIME. The compensating control is that every XPC connection is validated here,
// at the point of use, against the audit token AND the pinned code identity of
// the calling process — see `isAcceptable`, which states the limits of that.
// It is genuinely weaker than a signature check and is documented as such rather
// than papered over. If a Developer ID is ever obtained, this should move to
// SMAppService and the connection check becomes defence in depth instead of the
// only defence.
//
// NOTHING INSTALLS OR CONNECTS TO THIS HELPER YET. It is built but not shipped:
// `build-app.sh` does not place it, and no client in the app opens a connection.
// That is deliberate and it is the reason fan control is not a shipped feature.
// The gate to shipping it is an installer that pins the client cdhash under a
// root-owned path — not more code here.

let machServiceName = "dev.noah.betterstats.helper"

// ─────────────────────────────────────────────────────────────────────────────

@objc protocol HelperProtocol {
    /// rpm is advisory: the helper re-clamps against the fan's own reported
    /// limits and will refuse a value it cannot justify. The caller is not
    /// trusted to have done that, even though the app does it too.
    func setFanSpeed(index: Int, rpm: Double, reply: @escaping (Bool, String) -> Void)
    /// Hand every fan back to macOS.
    func releaseFans(reply: @escaping (Bool, String) -> Void)
    func fanCount(reply: @escaping (Int) -> Void)
}

final class Helper: NSObject, HelperProtocol, NSXPCListenerDelegate {

    private let smc = SMC()
    /// Serialises hardware access. Two concurrent writes to the same key is not
    /// a race worth finding out the consequences of.
    private let queue = DispatchQueue(label: "helper.smc")

    // ── Connection validation ───────────────────────────────────────────────

    /// Accept only connections from a process whose executable is the
    /// BetterStats app we were installed alongside.
    ///
    /// Without a signature requirement this is the security boundary, so it is
    /// checked on the AUDIT TOKEN rather than on the pid alone: a pid can be
    /// recycled between the check and the use, and processIdentifier is
    /// documented as advisory for exactly that reason.
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        guard isAcceptable(conn) else {
            log("rejected connection from pid \(conn.processIdentifier)")
            return false
        }
        conn.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        conn.exportedObject = self
        conn.resume()
        return true
    }

    /// The client's code identity, pinned at install time.
    ///
    /// Read from a root-owned file next to the helper rather than compiled in,
    /// because the app's cdhash changes on every rebuild and a helper that has to
    /// be recompiled in lockstep with its client would simply be disabled by the
    /// first person it inconvenienced.
    private static let pinnedCDHash: String? = {
        let p = "/Library/Application Support/BetterStats/client.cdhash"
        // Must be root-owned and not group/world writable, or the pin is
        // decorative: anyone who can rewrite it can authorise themselves.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: p),
              (attrs[.ownerAccountID] as? NSNumber)?.intValue == 0,
              let perms = (attrs[.posixPermissions] as? NSNumber)?.int16Value,
              perms & 0o022 == 0,
              let s = try? String(contentsOfFile: p, encoding: .utf8) else { return nil }
        let h = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return h.isEmpty ? nil : h
    }()

    /// Is this connection allowed to drive the fans?
    ///
    /// The previous version of this check compared the caller's executable path
    /// against the suffix `/BetterStats.app/Contents/MacOS/BetterStatsApp`, which
    /// any user can satisfy by making that directory under `/tmp` and putting any
    /// binary in it. That is a local privilege escalation to root, and the comment
    /// above it claimed an audit-token check that the code did not perform.
    ///
    /// Two things are checked now, and neither is a path:
    ///
    ///  1. The caller is identified by its AUDIT TOKEN, not its pid. A pid can be
    ///     recycled between the check and the use — the caller exits, the kernel
    ///     reissues its pid to an attacker's process, and the connection that was
    ///     approved is now someone else's. The audit token names a specific
    ///     process instance and cannot be recycled.
    ///  2. Its code signature must match a cdhash pinned at install time. A cdhash
    ///     is a hash of the signed code itself, so re-signing ad-hoc under the
    ///     same identifier — which defeats an identifier-only requirement, and is
    ///     the documented weakness of this app's ad-hoc signing — produces a
    ///     different hash and is rejected.
    ///
    /// HONEST LIMIT, because this is the security boundary and overstating it is
    /// how the last version went wrong: with no Developer ID there is no signature
    /// check at INSTALL time, so this depends on the installer having pinned the
    /// right hash while it had admin authorisation. It is a real check on a
    /// trusted-on-first-use footing, not the launchd-verified guarantee SMJobBless
    /// gives. If the pin is missing or unreadable, every connection is refused —
    /// failing closed, because a root fan controller that accepts anyone is worse
    /// than one that works for nobody.
    private func isAcceptable(_ conn: NSXPCConnection) -> Bool {
        guard let pinned = Self.pinnedCDHash else {
            log("refusing: no client identity pinned at \(Self.pinDescription)")
            return false
        }
        guard let token = Self.auditToken(of: conn) else {
            log("refusing: no audit token for pid \(conn.processIdentifier)")
            return false
        }
        guard let hash = Self.cdHash(auditToken: token) else {
            log("refusing: caller has no readable code signature")
            return false
        }
        guard hash == pinned else {
            log("refusing: cdhash \(hash) does not match pinned \(pinned)")
            return false
        }
        return true
    }

    static let pinDescription = "/Library/Application Support/BetterStats/client.cdhash"

    /// NSXPCConnection exposes no public audit-token accessor, so this reads the
    /// documented-but-private `auditToken` property. Returning nil on failure and
    /// refusing the connection is the whole reason this is safe to do: if a macOS
    /// release removes the property the helper stops accepting anyone, rather than
    /// falling back to the pid check that was the original vulnerability.
    private static func auditToken(of conn: NSXPCConnection) -> audit_token_t? {
        guard conn.responds(to: Selector(("auditToken"))),
              let value = conn.value(forKey: "auditToken") as? NSValue else { return nil }
        // Checked against the boxed type's own encoding before copying: getValue
        // writes sizeof(the boxed type) bytes into our buffer, so a property that
        // ever changed shape would be a stack overwrite inside the one function
        // whose job is refusing untrusted callers.
        guard String(cString: value.objCType) == "{audit_token_t=[8I]}" else { return nil }
        var token = audit_token_t()
        withUnsafeMutableBytes(of: &token) {
            value.getValue($0.baseAddress!, size: MemoryLayout<audit_token_t>.size)
        }
        return token
    }

    /// The caller's cdhash, lowercase hex, or nil if it has no valid signature.
    private static func cdHash(auditToken token: audit_token_t) -> String? {
        var t = token
        let data = withUnsafeBytes(of: &t) { Data($0) }
        let attrs = [kSecGuestAttributeAudit: data] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess,
              let code else { return nil }
        // Validity first: an unsigned or tampered client must not merely fail to
        // match, it must fail to produce an identity at all.
        guard SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var infoCF: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &infoCF) == errSecSuccess,
              let info = infoCF as? [String: Any],
              let cdhash = info[kSecCodeInfoUnique as String] as? Data else { return nil }
        return cdhash.map { String(format: "%02x", $0) }.joined()
    }

    // ── Operations ──────────────────────────────────────────────────────────

    private func limits(for index: Int) -> FanPolicy.Limits? {
        guard let smc,
              let mn = smc.read("F\(index)Mn")?.value,
              let mx = smc.read("F\(index)Mx")?.value else { return nil }
        return FanPolicy.Limits(minRPM: mn, maxRPM: mx)
    }

    func setFanSpeed(index: Int, rpm: Double, reply: @escaping (Bool, String) -> Void) {
        queue.async { [self] in
            guard let smc else { return reply(false, "SMC unavailable") }
            guard index >= 0, index < 8 else { return reply(false, "fan index out of range") }

            // Re-clamped HERE, against limits read fresh from the hardware. The
            // app clamps too, but a privileged process that trusts its client's
            // arithmetic is not actually a boundary.
            switch FanPolicy.resolve(rpm: rpm, limits: limits(for: index)) {
            case .failure(let why):
                reply(false, "refused: \(why)")
            case .success(let safe):
                let ok = smc.writeFloat("F\(index)Tg", safe)
                log("set F\(index)Tg = \(safe) -> \(ok)")
                reply(ok, ok ? "set fan \(index) to \(Int(safe)) rpm"
                            : "SMC write failed (rc \(smc.lastError))")
            }
        }
    }

    func releaseFans(reply: @escaping (Bool, String) -> Void) {
        queue.async { [self] in
            guard let smc else { return reply(false, "SMC unavailable") }
            // Returning a fan to automatic control means writing its MINIMUM
            // target, not zero. Zero is a request to stop the fan, and if the
            // firmware honoured it literally on a warm machine that is the worst
            // possible outcome of a function whose entire job is "stop meddling".
            var all = true
            for i in 0..<8 {
                guard let l = limits(for: i) else { continue }
                if !smc.writeFloat("F\(i)Tg", l.minRPM) { all = false }
            }
            log("released fans -> \(all)")
            reply(all, all ? "fans returned to automatic control"
                           : "one or more fans did not accept the release")
        }
    }

    func fanCount(reply: @escaping (Int) -> Void) {
        queue.async { [self] in
            reply(Int(self.smc?.read("FNum")?.value ?? 0))
        }
    }

    private func log(_ s: String) {
        FileHandle.standardError.write("betterstats-helper: \(s)\n".data(using: .utf8)!)
    }
}

// ─────────────────────────────────────────────────────────────────────────────

let helper = Helper()
let listener = NSXPCListener(machServiceName: machServiceName)
listener.delegate = helper
listener.resume()
RunLoop.main.run()
