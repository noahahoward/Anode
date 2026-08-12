import Foundation
import PowerKit

// AnodeHelper — the only part of this project that runs as root.
//
// It exists for exactly one reason: SMC writes require root, and fan control is
// an SMC write. Everything else in Anode is deliberately unprivileged.
//
// The whole privileged surface is two operations: set one fan to one speed, and
// stop controlling the fans. It is small enough to audit in one sitting, and
// that is the point — a root daemon you cannot read in full is a root daemon you
// cannot trust.
//
// IT RUNS TWO WAYS, and the default installs nothing.
//
//   sudo AnodeHelper            a SESSION helper. Nothing is installed, no
//                                     plist, no root process on this machine
//                                     when you are not using fan control. Started
//                                     by hand, stopped with ⌃C. It pins ONE BUILD
//                                     by cdhash, computed at startup from the app
//                                     bundle it shipped inside, so the pin cannot
//                                     go stale: it lives and dies with the
//                                     process. This is the development path and
//                                     the stronger of the two.
//
//   --install                         copy this helper somewhere only root can
//                                     write, and write a LaunchDaemon plist
//                                     naming it. One authorisation, then fan
//                                     control works across rebuilds and reboots
//                                     without ever prompting again. The daemon it
//                                     installs runs with --serve and pins the
//                                     SIGNING IDENTIFIER instead of a hash,
//                                     because a hash cannot survive a rebuild.
//
// The reasoning behind both — and the trust model each buys, including what the
// installed one gives up — is written out in full at the top of `FanLink.swift`
// and `FanDaemon.swift`. Read them before changing anything here.
//
// `--uninstall` hands the fans back and removes everything any version of this
// project has ever asked root to leave on the disk, including the retired
// LaunchDaemon from the first draft.

let arguments = Array(CommandLine.arguments.dropFirst())

func printErr(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

let usage = """
AnodeHelper — fan control for Anode. Runs as root.

  sudo AnodeHelper                start fan control for this session only.
                                        Nothing is installed. ⌃C stops it.
  sudo AnodeHelper --install      install it as a LaunchDaemon: one
                                        authorisation, then it works across
                                        rebuilds and reboots with no more prompts
  sudo AnodeHelper --uninstall    hand the fans back and remove everything
                                        this project has ever installed as root
       AnodeHelper --help

Options
  --client <path>   the Anode.app allowed to connect. Defaults to the
                    bundle this helper is inside, which is what you want.
  --uid <n>         the user allowed to connect. Defaults to $SUDO_UID, i.e.
                    whoever typed sudo.
  --serve           run as the installed daemon. launchd passes this; you should
                    not.

SESSION (the default) is the stronger of the two. While it runs, one program can
drive your fans: the exact Anode build this helper shipped beside, running
as you. Not another user, not another program of yours, not a rebuilt
Anode. Stop it with ⌃C and the fans go back to automatic.

INSTALLED is the convenient one. It is started ON DEMAND — launchd holds the
socket and runs it when the app connects, and it exits again once it has been
idle and holds no fan — so installing it does not put a root process on your
machine at boot or while Anode is closed.

It is weaker than the session helper in one specific way you should know before
you type a password: the daemon outlives your rebuilds, so it cannot pin a hash
that changes on every rebuild. It pins the signing identifier instead, and anyone
who can run `codesign -s - -i dev.noah.anode` on their own binary satisfies
that. So while it is up, ANYTHING RUNNING AS YOU can set your fan speeds, within
the range the fan itself reports. Nothing else can: other users are refused by
the kernel, and the daemon's whole vocabulary is "set fan N to R rpm" and
"release".
"""

func value(after flag: String) -> String? {
    guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}

if arguments.contains("--help") || arguments.contains("-h") {
    print(usage)
    exit(0)
}

// Every path below writes to hardware or to /Library. Checking once, here, means
// a user who forgets `sudo` gets a sentence instead of a permission error from
// somewhere in the middle of a teardown.
guard geteuid() == 0 else {
    printErr("AnodeHelper must run as root — try `sudo \(CommandLine.arguments[0])`.")
    exit(1)
}

// ── Uninstall ───────────────────────────────────────────────────────────────

if arguments.contains("--uninstall") {
    print("Handing the fans back to macOS…")
    // `toAutomatic`, not the session release. This process holds no history, so
    // there is no "original" to restore; it writes the measured no-forced-target
    // value and says so. This is the path for "an app that pinned my fans has
    // been deleted", and leaving them pinned is the failure it exists for.
    let result = FanRelease.toAutomatic(hardware: SMCFanHardware())
    print("  \(result.message)")

    // launchctl first: removing a plist does not unload a job that is already
    // running, and a bootout after the file is gone has nothing to name. Both
    // labels — the retired draft's and the current one — because a machine may
    // have either.
    for label in FanHelperInstall.daemonLabels {
        let plist = "/Library/LaunchDaemons/\(label).plist"
        guard FileManager.default.fileExists(atPath: plist) else { continue }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", "system/\(label)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        print("  unloaded \(label)")
    }

    for removal in FanHelperInstall.removeArtifacts() {
        switch removal.outcome {
        case .removed:          print("  removed  \(removal.path)")
        case .absent:           print("  not there \(removal.path)")
        case .notEmpty:         print("  kept     \(removal.path) — it holds something else")
        case .failed(let why):  print("  FAILED   \(removal.path): \(why)")
        }
    }
    print("Done. Nothing of this project runs as root any more.")
    exit(0)
}

// ── Install ─────────────────────────────────────────────────────────────────

/// This executable, resolved. What gets copied to /Library, and the one thing
/// this program can name with certainty.
let selfPath = URL(fileURLWithPath: CommandLine.arguments[0])
    .resolvingSymlinksInPath().path

if arguments.contains(FanDaemon.installArgument) {
    /// The user the daemon will serve.
    ///
    /// `--uid` first, and the app's Install button always passes it: that route
    /// goes through `do shell script … with administrator privileges`, which does
    /// NOT go through sudo and does NOT set $SUDO_UID. The fallback is for a
    /// person typing `sudo … --install` in a terminal, where it is set and is
    /// exactly who asked.
    let installFor: uid_t? = {
        if let raw = value(after: "--uid"), let n = UInt32(raw) { return uid_t(n) }
        if let raw = ProcessInfo.processInfo.environment["SUDO_UID"], let n = UInt32(raw) {
            return uid_t(n)
        }
        return nil
    }()
    guard let installFor else {
        printErr("Cannot tell which user to install for. Run this with `sudo` "
               + "(which sets SUDO_UID), or pass --uid <n>.")
        exit(1)
    }

    // The bundle around this helper, and the identifier it signs as. Checked
    // BEFORE anything is written: a daemon installed from a bundle that signs as
    // something else would install perfectly and then refuse every connection,
    // which is the worst kind of working.
    let bundle = URL(fileURLWithPath: selfPath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let identifier = FanIdentity.identity(atPath: bundle.path)?.identifier

    let plan: FanDaemonInstall.Plan
    switch FanDaemonInstall.plan(sourceHelper: selfPath, ownerUID: installFor,
                                 clientIdentifier: identifier) {
    case .failure(let refusal):
        printErr(refusal.localizedDescription)
        exit(1)
    case .success(let p):
        plan = p
    }

    print("""
    Installing the Anode fan helper as a launch daemon.

      helper   \(FanDaemon.helperPath)   (root:wheel 0755, copied from this build)
      plist    \(FanDaemon.plistPath)    (root:wheel 0644)
      serves   uid \(installFor)
      accepts  any build signing as \(FanDaemon.clientSigningIdentifier)

    It is started ON DEMAND. launchd holds the socket and runs the helper when
    something connects; it exits again after \(Int(FanDaemon.idleExit))s with no client and no
    fan held. Nothing of this runs at boot, or while Anode is closed.

    While it is up it will set a fan target on request from uid \(installFor), within
    the range the fan itself reports. Anything running as that user can ask —
    this build has no Apple Developer ID, so nothing can tell your Anode
    from another program that signs itself with the same identifier. Undo it all
    with --uninstall.
    """)

    let report = FanDaemonInstall.perform(plan, ops: FanDaemonInstall.SystemOperations())
    for outcome in report.outcomes {
        print("  \(outcome.ok ? "ok    " : "FAILED") \(outcome.path) — \(outcome.detail)")
    }
    guard report.ok else {
        printErr("The install did not finish. Nothing is loaded; run --uninstall "
               + "to clear anything that did land.")
        exit(1)
    }
    print("Done. Fan control now works with no further prompts, including after "
        + "you rebuild the app and after a reboot.")
    exit(0)
}

// ── Who this helper serves ──────────────────────────────────────────────────

/// The app bundle allowed to talk to us.
///
/// Defaults to the bundle this executable sits inside
/// (`Anode.app/Contents/MacOS/AnodeHelper`), which means the user
/// authorises one specific pair of binaries by typing one path after `sudo`.
/// `--client` overrides it for development; that gives nothing away, because
/// anyone who can pass it is already root.
func defaultClientBundle() -> String? {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let bundle = exe.deletingLastPathComponent()   // MacOS
        .deletingLastPathComponent()               // Contents
        .deletingLastPathComponent()               // Anode.app
    return bundle.pathExtension == "app" ? bundle.path : nil
}

/// Which of the two this is. launchd passes `--serve`; a person does not.
let isInstalledDaemon = arguments.contains(FanDaemon.serveArgument)

// One socket, one owner. A session helper started while the daemon is installed
// would unlink the daemon's socket and bind its own — the daemon would stay
// running, listening on a path nothing can reach, and the fans would answer to
// whichever process won a race. Refused, with the way out.
if !isInstalledDaemon, FanDaemon.isInstalled() {
    printErr("""
    The fan helper is already INSTALLED as a launch daemon. launchd is holding \
    \(FanSocket.path) and starts the helper when the app connects. Starting a \
    second one by hand would unlink that socket and bind its own, and launchd \
    would never start another helper — the path it is waiting on would be gone.

    Fan control should already work — just use the Fans tab. To go back to the \
    session helper instead:

      sudo \(CommandLine.arguments[0]) --uninstall
    """)
    exit(1)
}

/// Which client this helper answers.
///
/// The session helper pins ONE BUILD, by a cdhash read from the bundle it lives
/// in at startup. The installed daemon cannot: it outlives every rebuild, so it
/// pins the signing identifier, and `FanClientPin` states exactly what that is
/// worth. This is the only difference between the two.
let pin: FanClientPin
let clientDescription: String

if isInstalledDaemon {
    pin = .signingIdentifier(FanDaemon.clientSigningIdentifier)
    clientDescription = "any build signing as \(FanDaemon.clientSigningIdentifier)"
} else {
    guard let clientPath = value(after: "--client") ?? defaultClientBundle() else {
        printErr("""
        This helper is not inside a Anode.app, so it cannot tell which app to \
        trust. Run the copy inside the bundle:

          sudo ~/Applications/Anode.app/Contents/MacOS/AnodeHelper

        or name the bundle explicitly with --client <path to Anode.app>.
        """)
        exit(1)
    }
    // Fail closed, loudly, at startup. An unpinned helper would accept any
    // program of yours; refusing to start at all is the only honest response to
    // "I cannot tell who I am supposed to be talking to".
    guard let pinned = FanIdentity.cdhash(atPath: clientPath) else {
        printErr("Could not read a code signature for \(clientPath). "
               + "Fan control needs one to tell your Anode from anything else, "
               + "so this helper will not start.")
        exit(1)
    }
    pin = .exactBuild(cdhash: pinned)
    clientDescription = "\(clientPath)\n           cdhash \(pinned.prefix(16))…"
}

/// The user allowed to connect: whoever typed `sudo`.
///
/// Refused rather than guessed. Defaulting to the console user would let a
/// helper started in one login session serve a different one, and defaulting to
/// root would serve nobody, silently.
let ownerUID: uid_t = {
    if let raw = value(after: "--uid"), let n = UInt32(raw) { return uid_t(n) }
    if let raw = ProcessInfo.processInfo.environment["SUDO_UID"], let n = UInt32(raw) {
        return uid_t(n)
    }
    printErr("Cannot tell which user to serve. Start this with `sudo` (which sets "
           + "SUDO_UID), or pass --uid <n>.")
    exit(1)
}()

// ── Run ─────────────────────────────────────────────────────────────────────

let server = FanHelperServer(
    hardware: SMCFanHardware(),
    configuration: .init(ownerUID: ownerUID, pin: pin),
    // Both sinks, deliberately. stderr is what the user reads live in the
    // Terminal window they started this in — but that window closes, and then a
    // failure has left no trace. The unified log survives it, which is the only
    // way to diagnose a path that cannot be exercised without root:
    //
    //     log show --predicate 'subsystem == "dev.noah.anode"' --last 10m
    log: {
        printErr("anode-helper: \($0)")
        fanLog.info("helper: \($0, privacy: .public)")
    })

do {
    if isInstalledDaemon {
        // The installed daemon is started BY a connection, not before one. It
        // does not create the socket — launchd made it at install time, has been
        // holding it ever since, and hands it over here. That is what keeps this
        // off the machine entirely until fan control is used.
        server.idleExit = FanDaemon.idleExit
        try server.start(adopting: FanDaemon.activatedSocket())
    } else {
        try server.start()
    }
} catch let failure as FanDaemon.ActivationFailure {
    // These are worth more than an errno: two of the four mean someone ran
    // `--serve` by hand, and the sentence says so instead of printing a number.
    printErr("anode-helper: \(failure.message)")
    exit(1)
} catch {
    printErr("anode-helper: \(error.localizedDescription)")
    exit(1)
}

// Said out loud at the moment the user authorises it, because this is the only
// point where a person is looking at the decision. A trust model buried in a
// source file is not disclosure to the person typing the password.
//
// The daemon prints the same facts to the unified log rather than to a terminal
// nobody is watching — its disclosure happened at install time, in the sheet and
// in the authorisation prompt.
if isInstalledDaemon {
    fanLog.info("""
    installed daemon serving uid \(ownerUID, privacy: .public) on \
    \(FanSocket.path, privacy: .public), accepting \
    \(clientDescription, privacy: .public)
    """)
} else {
    print("""
    Anode fan control is running as root.

      client   \(clientDescription)
      user     uid \(ownerUID)
      socket   \(FanSocket.path)

    Only that exact build, run by that user, can set a fan speed — and only within
    the min/max the fan itself reports. Rebuild Anode and this helper will stop
    recognising it; stop and start it again if you still want fan control.

    Press ⌃C to stop. The fans return to automatic control when you do, and also if
    Anode quits or crashes.
    """)
}

// DispatchSource rather than a signal(3) handler: the handler would run on the
// interrupted thread with only async-signal-safe calls available, and `stop()`
// is called from it. A dispatch source runs on an ordinary queue, so there is no
// such rule to break. SIG_IGN first, or the default action kills us before the
// source ever sees it.
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
    let s = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    s.setEventHandler { server.stop() }
    s.resume()
    return s
}
_ = sources   // held for the life of the process; a released source stops firing

server.run()
// SIGKILL is the one exit this cannot cover: nothing runs, and a fan set
// manually stays set until something writes it again. `--uninstall` is the way
// out of that, and it is why that command releases unconditionally.
print("Fan control stopped.")
