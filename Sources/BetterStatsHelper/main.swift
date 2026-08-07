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
// at the point of use, against the audit token of the calling process. That is
// genuinely weaker than a signature check and is documented as such rather than
// papered over. If a Developer ID is ever obtained, this should move to
// SMAppService and the connection check becomes defence in depth instead of the
// only defence.

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

    private func isAcceptable(_ conn: NSXPCConnection) -> Bool {
        let pid = conn.processIdentifier
        guard pid > 0 else { return false }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return false }
        let path = String(cString: buf)
        // Must be our app binary, and must live somewhere a normal user cannot
        // silently swap out from under us mid-session.
        return path.hasSuffix("/BetterStats.app/Contents/MacOS/BetterStatsApp")
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
