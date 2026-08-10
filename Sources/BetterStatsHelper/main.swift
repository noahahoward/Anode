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
// IT IS NOT A DAEMON, AND NOTHING INSTALLS IT. There is no LaunchDaemon, no
// plist, no pinned-identity file, and no root process on this machine when you
// are not using fan control. The user starts this program by hand, under sudo,
// and stops it with ⌃C. That is the whole install.
//
// The reasoning behind that — and the trust model it buys — is written out in
// full at the top of `FanLink.swift`. The short version: this project has no
// Apple Developer ID, so nothing can verify a helper binary before it runs as
// root; the previous design pinned the client's cdhash in a root-owned file at
// install time, and an ad-hoc cdhash changes on every rebuild, so the pin went
// stale after every `./build-app.sh` and the repair was another admin prompt.
// Training a user to type their password on demand is a worse outcome than the
// bug the pin closed. Here the pin is computed at startup from the app bundle
// this helper shipped inside, so it cannot go stale: it lives and dies with the
// process.
//
// `--uninstall` releases the fans and removes everything any version of this
// project has ever asked root to leave on the disk, including the retired
// LaunchDaemon.

let arguments = Array(CommandLine.arguments.dropFirst())

func printErr(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

let usage = """
BetterStatsHelper — fan control for BetterStats. Runs as root, only while you run it.

  sudo BetterStatsHelper                start fan control for this session
  sudo BetterStatsHelper --uninstall    hand the fans back and remove everything
                                        this project has ever installed as root
       BetterStatsHelper --help

Options
  --client <path>   the BetterStats.app allowed to connect. Defaults to the
                    bundle this helper is inside, which is what you want.
  --uid <n>         the user allowed to connect. Defaults to $SUDO_UID, i.e.
                    whoever typed sudo.

While it runs, one program can drive your fans: the exact BetterStats build this
helper shipped beside, running as you. Nothing else is heard — not another user,
not another program of yours, not a rebuilt BetterStats. Stop it with ⌃C and the
fans go back to automatic control.
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
    printErr("BetterStatsHelper must run as root — try `sudo \(CommandLine.arguments[0])`.")
    exit(1)
}

// ── Uninstall ───────────────────────────────────────────────────────────────

if arguments.contains("--uninstall") {
    print("Handing the fans back to macOS…")
    // Unconditional, unlike the running helper's release. This is the path for
    // "an app that pinned my fans has been deleted", so there is no session
    // whose history could say whether a write is needed — and leaving a fan
    // held by software that is gone is the failure this command exists for.
    let result = FanRelease.all(hardware: SMCFanHardware())
    print("  \(result.message)")

    // launchctl first: removing a plist does not unload a job that is already
    // running, and a bootout after the file is gone has nothing to name.
    let label = FanHelperInstall.retiredDaemonLabel
    let plist = "/Library/LaunchDaemons/\(label).plist"
    if FileManager.default.fileExists(atPath: plist) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", "system/\(label)"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        print("  unloaded the retired launch daemon")
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

// ── Who this helper serves ──────────────────────────────────────────────────

/// The app bundle allowed to talk to us.
///
/// Defaults to the bundle this executable sits inside
/// (`BetterStats.app/Contents/MacOS/BetterStatsHelper`), which means the user
/// authorises one specific pair of binaries by typing one path after `sudo`.
/// `--client` overrides it for development; that gives nothing away, because
/// anyone who can pass it is already root.
func defaultClientBundle() -> String? {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let bundle = exe.deletingLastPathComponent()   // MacOS
        .deletingLastPathComponent()               // Contents
        .deletingLastPathComponent()               // BetterStats.app
    return bundle.pathExtension == "app" ? bundle.path : nil
}

guard let clientPath = value(after: "--client") ?? defaultClientBundle() else {
    printErr("""
    This helper is not inside a BetterStats.app, so it cannot tell which app to \
    trust. Run the copy inside the bundle:

      sudo ~/Applications/BetterStats.app/Contents/MacOS/BetterStatsHelper

    or name the bundle explicitly with --client <path to BetterStats.app>.
    """)
    exit(1)
}

// Fail closed, loudly, at startup. An unpinned helper would accept any program
// of yours; refusing to start at all is the only honest response to "I cannot
// tell who I am supposed to be talking to".
guard let pinned = FanIdentity.cdhash(atPath: clientPath) else {
    printErr("Could not read a code signature for \(clientPath). "
           + "Fan control needs one to tell your BetterStats from anything else, "
           + "so this helper will not start.")
    exit(1)
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
    configuration: .init(ownerUID: ownerUID, pinnedCDHash: pinned),
    // Both sinks, deliberately. stderr is what the user reads live in the
    // Terminal window they started this in — but that window closes, and then a
    // failure has left no trace. The unified log survives it, which is the only
    // way to diagnose a path that cannot be exercised without root:
    //
    //     log show --predicate 'subsystem == "dev.noah.betterstats"' --last 10m
    log: {
        printErr("betterstats-helper: \($0)")
        fanLog.info("helper: \($0, privacy: .public)")
    })

do {
    try server.start()
} catch {
    printErr("betterstats-helper: \(error.localizedDescription)")
    exit(1)
}

// Said out loud at the moment the user authorises it, because this is the only
// point where a person is looking at the decision. A trust model buried in a
// source file is not disclosure to the person typing the password.
print("""
BetterStats fan control is running as root.

  client   \(clientPath)
           cdhash \(pinned.prefix(16))…
  user     uid \(ownerUID)
  socket   \(FanSocket.path)

Only that exact build, run by that user, can set a fan speed — and only within
the min/max the fan itself reports. Rebuild BetterStats and this helper will stop
recognising it; stop and start it again if you still want fan control.

Press ⌃C to stop. The fans return to automatic control when you do, and also if
BetterStats quits or crashes.
""")

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
