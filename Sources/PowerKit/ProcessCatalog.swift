import Foundation

/// What a process IS, in words — and, for every word, where it came from.
///
/// This is the same problem `SensorNaming` solves, with the same rule and for the
/// same reason. A sensor list with a wrong label tells the user which component to
/// blame; a process list with a wrong description tells them what to kill. Both
/// failures are silent, both are permanent, and in both cases the raw identity
/// (`TVDc`, `/usr/libexec/textcontextd`) carries no claim at all and is therefore
/// safer than a plausible guess.
///
/// The app has NO network access and is not getting any, so everything here is
/// read off this machine. Four sources, strongest first:
///
///   APPLE'S OWN WORDS — the man page macOS ships in `/usr/share/man`. This is the
///                 strongest source available and it is not a guess in any sense:
///                 Apple wrote the sentence, it shipped with the OS version that
///                 is actually installed, and it is a plain file on disk.
///                 `biomesyncd` -> "data synchronization daemon"; `cfprefsd` ->
///                 "provides preferences services for the CFPreferences and
///                 NSUserDefaults APIs". MEASURED on this machine: 292 of the 684
///                 distinct running process names have one — 43%.
///   BUNDLE       — strings Apple (or the developer) put in `Info.plist`:
///                 `CFBundleDisplayName`, `NSHumanReadableCopyright`, the
///                 extension point a `.appex` plugs into. Also authored, also
///                 read at runtime, also not a guess.
///   STRUCTURE    — where the file lives, who signed it, and which launchd job
///                 owns it. This says nothing about PURPOSE and is not supposed
///                 to: "signed by Apple, inside the sealed system volume, started
///                 by launchd as root" is a complete and true answer to "is this
///                 Apple's, and why is it running", which is most of the question.
///   CURATED      — a sentence written here. Admitted ONLY when the three sources
///                 above produce nothing AND a string Apple ships on this machine
///                 spells out what the binary name hides, so the claim can be
///                 re-checked on any Mac. Every entry names that string.
///
/// The table below is therefore SMALL, and that is the finding rather than a gap.
/// MEASURED here: 64 running executables are bare binaries in system locations
/// with no man page and no bundle — `textcontextd`, `mlhostd`, `dprivacyd`,
/// `corerepaird`. Their launchd jobs carry no description key (surveyed all 928
/// job plists on this machine: `Label`, `MachServices`, `ProgramArguments`, and
/// no human-readable field anywhere), and nothing else on disk says what they do.
/// Writing a sentence for them would be inventing one. They fall through to
/// STRUCTURE plus their published Mach service names, which is exactly the
/// "Thermal sensor N + raw key" treatment: an honest unknown with its real
/// identity attached.
public enum ProcessCatalog {

    // ── Curated: path families ──────────────────────────────────────────────

    /// Directories whose meaning IS the artifact.
    ///
    /// Every one of these is a claim about a location, not about a program, and
    /// the location is verifiable with `ls`. `/System/Library/DriverExtensions`
    /// contains DriverKit bundles because that is the directory DriverKit loads
    /// from — the `.dext` suffix and `CFBundlePackageType = DEXT` in each one's
    /// `Info.plist` corroborate it on this machine.
    ///
    /// Matched LONGEST PREFIX FIRST, so `/usr/libexec/rosetta/` wins over any
    /// broader `/usr/` rule that might be added later.
    static let pathFamilies: [(prefix: String, text: String)] = [
        ("/System/Library/DriverExtensions/",
         "A DriverKit driver extension — a hardware driver that runs as an ordinary "
         + "user-space process instead of inside the kernel."),
        ("/System/Library/ExtensionKit/Extensions/",
         "A system app extension. macOS starts it on demand for whichever process "
         + "asked for its extension point, and stops it again afterwards."),
        ("/System/Library/CoreServices/",
         "Part of the core services layer of macOS — the processes that make the "
         + "desktop itself work."),
        ("/System/Cryptexes/",
         "Shipped inside a cryptex: a sealed, signed disk image Apple can replace "
         + "without reinstalling macOS. Safari and its helpers live here."),
        ("/usr/libexec/rosetta/",
         "Part of Rosetta 2, which translates Intel code so it can run on Apple "
         + "silicon."),
        ("/Library/Apple/System/Library/",
         "Installed by an Apple software update rather than by the macOS installer."),
    ]

    // ── Curated: individual binaries ────────────────────────────────────────

    /// Keyed by ABSOLUTE PATH, never by process name.
    ///
    /// A name is not an identity — anyone can build a binary called `dasd` and put
    /// it in their home directory — while a path inside the sealed system volume
    /// can only have been written by Apple's installer. Keying on the name is the
    /// bug that would let a user's `~/bin/dasd` inherit Apple's description, which
    /// is the same class of error as handing an SMC key a neighbour's label.
    ///
    /// `/usr/libexec/dasd` — its launchd job (`/System/Library/LaunchDaemons/
    /// com.apple.dasd.plist`) publishes exactly one Mach service, and that service
    /// is named `com.apple.duetactivityscheduler`. The four-letter binary name
    /// hides a phrase Apple spelled out in full one file away.
    ///
    /// `/usr/libexec/aned` — same shape: its job publishes
    /// `com.apple.appleneuralengine` and `com.apple.appleneuralengine.private`.
    ///
    /// Both entries do nothing but render a string this code already reads at
    /// runtime, so if either job is ever renamed the corroboration disappears with
    /// it and the entry should go too.
    static let binaries: [String: String] = [
        "/usr/libexec/dasd":
            "Schedules background activity on behalf of other processes. Its launchd "
            + "job publishes it as \"com.apple.duetactivityscheduler\".",
        "/usr/libexec/aned":
            "The Apple Neural Engine service. Its launchd job publishes it as "
            + "\"com.apple.appleneuralengine\".",
    ]

    /// The curated sentence for an executable path, if there is one.
    static func curated(forExecutablePath path: String) -> String? {
        if let exact = binaries[path] { return exact }
        return pathFamilies
            .filter { path.hasPrefix($0.prefix) }
            .max { $0.prefix.count < $1.prefix.count }?
            .text
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// Apple's own one-line description of a system binary, read from the man page
/// that shipped with this copy of macOS.
///
/// Worth the parser: this is the only source in the whole feature that describes
/// a daemon's PURPOSE without anyone here guessing at it. `duetexpertd` — a name
/// that tells a user nothing and is a frequent "what is this and can I kill it"
/// — ships `/usr/share/man/man8/duetexpertd.8`, which says it "powers
/// personalized system experiences". That sentence is Apple's, it is on disk, and
/// reading it costs one file read.
///
/// THE GATE MATTERS. Man pages are looked up by the executable's BASENAME, and a
/// basename is not an identity: a user's `~/bin/mds` would otherwise inherit
/// Apple's description of Spotlight's metadata server. So a lookup is only
/// attempted for executables inside SIP-protected system locations, where the
/// only writer is Apple's installer and the man page and the binary came out of
/// the same OS build. See `ManPage.describes(executableAt:)`.
public enum ManPage {

    /// Sections searched, in order. 8 is system administration — where daemons
    /// live — and 1 is user commands, which is where a few of them ended up
    /// anyway (`securityd`, `powerd`). Nothing else is consulted: section 3 is
    /// library calls, and a daemon sharing a name with a C function is a
    /// collision, not a description.
    static let sections = ["8", "1"]

    static let root = "/usr/share/man"

    /// True when a man page may be attributed to this executable at all.
    ///
    /// `/usr/local` is deliberately excluded: it is the one path under `/usr` that
    /// is writable without SIP, which makes it exactly the place a name collision
    /// would come from.
    public static func describes(executableAt path: String) -> Bool {
        guard !path.hasPrefix("/usr/local/") else { return false }
        return ["/usr/", "/bin/", "/sbin/", "/System/"].contains { path.hasPrefix($0) }
    }

    /// Apple's description of the binary at `path`, or nil.
    public static func description(forExecutableAt path: String) -> String? {
        guard describes(executableAt: path) else { return nil }
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty else { return nil }

        for section in sections {
            let file = "\(root)/man\(section)/\(name).\(section)"
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            if let d = parse(text, name: name) { return d }
        }
        return nil
    }

    // ── mdoc ────────────────────────────────────────────────────────────────

    /// Pull a one-line description out of an mdoc page.
    ///
    /// Pure, and separate from the file read, because the parsing is the part with
    /// edge cases and the file read is the part that depends on which Mac this is.
    ///
    /// Two sources inside the page, in order:
    ///   1. `.Nd` — mdoc's own one-line description field, and the right answer
    ///      when it exists. MEASURED: 691 of the 849 section-8 pages on this
    ///      machine have one.
    ///   2. The first sentence of `DESCRIPTION`, for the rest. `duetexpertd` has
    ///      no `.Nd` at all; its DESCRIPTION reads ".Nm / powers personalized
    ///      system experiences." — which is a complete sentence once `.Nm` is
    ///      expanded to the tool's name, and useless without that expansion.
    static func parse(_ page: String, name: String) -> String? {
        let lines = page
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix(".\\\"") }        // roff comments

        if let nd = lines.first(where: { $0.hasPrefix(".Nd ") }) {
            if let text = clean(String(nd.dropFirst(4)), name: name) { return text }
        }

        guard let start = lines.firstIndex(where: {
            $0.hasPrefix(".Sh DESCRIPTION") || $0.hasPrefix(".Sh \"DESCRIPTION")
        }) else { return nil }

        var words: [String] = []
        for line in lines[lines.index(after: start)...] {
            if line.hasPrefix(".Sh") || line.hasPrefix(".Pp") { break }
            if line.hasPrefix(".") {
                // `.Nm` alone on a line is the tool's name used as a sentence
                // subject. Every other macro is formatting we do not need, and
                // guessing at its argument would be inventing text.
                let macro = line.trimmingCharacters(in: .whitespaces)
                if macro == ".Nm" || macro == ".Nm ." { words.append(name) }
                continue
            }
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { words.append(t) }
            // One sentence only. A DESCRIPTION can run for pages, and everything
            // after the first full stop is detail the inspector has no room for.
            if t.contains(".") { break }
        }
        guard !words.isEmpty else { return nil }
        let joined = words.joined(separator: " ")
        let sentence = joined.firstIndex(of: ".").map { String(joined[...$0]) } ?? joined
        return clean(sentence, name: name)
    }

    /// Strip roff escapes and reject anything that is not a usable sentence.
    private static func clean(_ raw: String, name: String) -> String? {
        var s = raw
        for (escape, replacement) in [("\\fB", ""), ("\\fI", ""), ("\\fR", ""),
                                      ("\\fP", ""), ("\\&", ""), ("\\-", "-"),
                                      ("\\ ", " "), ("\\e", "\\")] {
            s = s.replacingOccurrences(of: escape, with: replacement)
        }
        s = s.replacingOccurrences(of: "\"", with: "")
             .trimmingCharacters(in: .whitespacesAndNewlines)

        // A page whose description is nothing but the tool's own name says
        // nothing; printing "duetexpertd: duetexpertd" is worse than printing
        // the structural facts.
        guard !s.isEmpty, s.count <= 300, s.lowercased() != name.lowercased() else { return nil }
        // Any leftover macro means the parse went wrong. Better to fall through
        // to STRUCTURE than to show a user a line of roff.
        guard !s.hasPrefix(".") else { return nil }
        return s
    }
}
