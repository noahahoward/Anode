import AppKit
import Security

// ── Approvals that belong to an older build ─────────────────────────────────
//
// macOS remembers a privacy approval (Accessibility, Screen Recording) against the program's code
// requirement. A build signed ad-hoc has the requirement "this exact cdhash", and every update has a new one,
// so the old approval stays switched on in System Settings and stops applying: `AXIsProcessTrusted` is false
// with the switch lit, and switching it off and on keeps the old requirement. Measured on a MacBook Neo:
// signature=ad-hoc, trusted=false, the same cdhash across launches, working again only after
// `tccutil reset Accessibility`.
//
// The lasting answer is a signing identity of its own, which build-app.sh now makes on the first build so the
// requirement stops changing (see make-signing-identity.sh). This is for what that cannot reach: a Mac that
// declined it, or the first update after it was made, whose approvals were given to the ad-hoc build. It
// clears the dead approval and asks again, once for each build, so a feature that is switched on and cannot
// work is put right by the next launch rather than left looking fine.

/// How this running copy of Anode is signed.
struct CodeIdentity: Equatable {
    /// "ad-hoc", "certificate" or "unsigned".
    let kind: String
    /// The first four bytes of the code directory hash, as hex; changes with every build.
    let cdhash: String
    let identifier: String

    static func current() -> CodeIdentity? {
        var me: SecCode?
        var staticCode: SecStaticCode?
        var infoCF: CFDictionary?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF)
                == errSecSuccess,
              let info = infoCF as? [String: Any] else { return nil }
        let flags = (info[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        let kind = flags & SecCodeSignatureFlags.adhoc.rawValue != 0 ? "ad-hoc"
                 : info[kSecCodeInfoCertificates as String] != nil ? "certificate" : "unsigned"
        let hash = (info[kSecCodeInfoUnique as String] as? Data)?.map { String(format: "%02x", $0) }.joined() ?? ""
        return CodeIdentity(kind: kind, cdhash: hash, identifier: (info[kSecCodeInfoIdentifier as String] as? String) ?? "?")
    }
}

enum ApprovalRepair {

    /// The TCC service names `tccutil` takes.
    enum Service: String {
        case accessibility = "Accessibility"
        case screenRecording = "ScreenCapture"
    }

    /// Whether to repair now: only for a build that has not been repaired for yet. Pure, for tests.
    /// `current` is the running build's cdhash, nil when it cannot be read (then nothing is done).
    static func shouldRepair(lastRepairedFor stored: String?, current: String?) -> Bool {
        guard let current, !current.isEmpty else { return false }
        return stored != current
    }

    /// Forget Anode's approval for `service`, then run `then` on the main thread. `tccutil` removes only
    /// this app's own entry and asks for no password. Safe to call from any thread.
    static func reset(_ service: Service, then: @escaping () -> Void) {
        let bundleID = Bundle.main.bundleIdentifier ?? "dev.anode.app"
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            p.arguments = ["reset", service.rawValue, bundleID]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            var ok = false
            if (try? p.run()) != nil { p.waitUntilExit(); ok = p.terminationStatus == 0 }
            FeatureLog.append("accessibility.log", "reset \(service.rawValue) for \(bundleID): \(ok ? "done" : "tccutil failed")")
            DispatchQueue.main.async(execute: then)
        }
    }

    /// For a feature that is switched on and refused: clear the approval and ask again, but only the first time
    /// this build is found refused, so a user who says no is asked once per update and not on every check.
    /// The build is recorded BEFORE the work, so a crash or a refusal cannot make it repeat.
    /// `clear` is `reset` unless a test swaps it, so no test runs the real `tccutil`.
    static func repairOncePerBuild(_ service: Service, defaults: UserDefaults = .standard,
                                   current: String? = CodeIdentity.current()?.cdhash,
                                   clear: (Service, @escaping () -> Void) -> Void = ApprovalRepair.reset,
                                   ask: @escaping () -> Void) {
        let key = "anode.approvalRepairedFor.\(service.rawValue)"
        guard shouldRepair(lastRepairedFor: defaults.string(forKey: key), current: current), let current else { return }
        defaults.set(current, forKey: key)
        clear(service, ask)
    }
}
