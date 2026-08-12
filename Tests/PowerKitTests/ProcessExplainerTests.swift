import XCTest
@testable import AnodeApp
@testable import PowerKit

/// "What is this process?" is the same kind of claim as a sensor name, and it
/// fails the same way: silently, permanently, and with the user acting on it.
/// A wrong sensor label tells someone which component to blame; a wrong process
/// description tells them what to kill.
///
/// So these tests pin both halves of the contract. The facts we read — where a
/// binary lives, what bundle wraps it, who signed it, which launchd job owns it —
/// have to be read correctly. And an executable that none of those sources
/// describes has to come back with NOTHING rather than with a plausible sentence.
final class ProcessExplainerTests: XCTestCase {

    // ── Where it lives ──────────────────────────────────────────────────────

    func testTheSealedSystemVolumeIsNotTheSameAsTheSystemBinaries() {
        XCTAssertEqual(InstallDomain.of(path: "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"),
                       .sealedSystem)
        XCTAssertEqual(InstallDomain.of(path: "/usr/libexec/duetexpertd"), .systemBinaries)
        XCTAssertEqual(InstallDomain.of(path: "/bin/ls"), .systemBinaries)
        XCTAssertEqual(InstallDomain.of(path: "/Applications/Brave Browser.app/Contents/MacOS/x"),
                       .applications)
    }

    /// `/usr/local` is the one path under `/usr` that SIP leaves writable, so it
    /// is where a name collision with an Apple binary would come from. Filing it
    /// under "system binaries" would let a Homebrew tool present itself with the
    /// authority of one.
    func testUsrLocalIsNotASystemLocation() {
        XCTAssertEqual(InstallDomain.of(path: "/usr/local/bin/mds"), .administrator)
        XCTAssertEqual(InstallDomain.of(path: "/opt/homebrew/bin/mds"), .administrator)
        XCTAssertEqual(InstallDomain.of(path: "/Library/PrivilegedHelperTools/x"), .administrator)
    }

    /// On an APFS boot volume group the user's own files are reachable at
    /// `/System/Volumes/Data/Users/...` as well as at `/Users/...`, and
    /// `proc_pidpath` returns the long form often enough to matter. Classifying
    /// the raw prefix would file a user's download under "sealed system volume",
    /// the single most misleading answer this function can give.
    func testTheDataFirmlinkIsStrippedBeforeAnythingIsClassified() {
        let home = "/Users/someone"
        XCTAssertEqual(InstallDomain.of(path: "/System/Volumes/Data/Users/someone/bin/tool",
                                        home: home), .userHome)
        XCTAssertEqual(InstallDomain.of(path: "/System/Volumes/Data/Applications/Thing.app/x",
                                        home: home), .applications)
    }

    func testHomeIsTakenFromTheCallerSoTheTestDoesNotDependOnWhoRunsIt() {
        XCTAssertEqual(InstallDomain.of(path: "/Users/someone/Downloads/x", home: "/Users/someone"),
                       .userHome)
        XCTAssertEqual(InstallDomain.of(path: "/Users/someone/Downloads/x", home: "/Users/other"),
                       .elsewhere)
    }

    func testNoExecutablePathIsUnknownRatherThanElsewhere() {
        // The kernel has no file on disk. "Unknown" and "somewhere unusual" are
        // different claims and only one of them is true.
        XCTAssertEqual(InstallDomain.of(path: ""), .unknown)
    }

    // ── What it is, and what it is part of ──────────────────────────────────

    /// The innermost bundle says what the process IS; the outermost `.app` says
    /// what it is part of. `AppResolver` takes only the outermost, because the
    /// process table must roll fifteen helpers into one row — this view needs
    /// both ends, and they are different answers.
    func testAHelperAppReportsItselfAndTheAppItBelongsTo() {
        let s = BundleShape.of(path: "/Applications/Brave Browser.app/Contents/Frameworks/"
                                   + "Brave Browser Helper.app/Contents/MacOS/Brave Browser Helper")
        XCTAssertEqual(s.form, .application)
        XCTAssertEqual(s.bundlePath, "/Applications/Brave Browser.app/Contents/Frameworks/"
                                   + "Brave Browser Helper.app")
        XCTAssertEqual(s.containerName, "Brave Browser")
    }

    /// A top-level app is not a helper of itself. Reporting "part of: Brave
    /// Browser" on Brave Browser's own row would be a process pointing at itself.
    func testATopLevelAppIsNotItsOwnContainer() {
        let s = BundleShape.of(path: "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser")
        XCTAssertEqual(s.form, .application)
        XCTAssertNil(s.containerPath)
        XCTAssertNil(s.containerName)
    }

    /// The suffixes are the ones macOS itself loads by, and the innermost wins:
    /// an `.appex` inside an `.app` is an app extension, not the app.
    func testTheInnermostBundleDecidesWhatKindOfThingItIs() {
        XCTAssertEqual(BundleShape.of(path: "/System/Library/ExtensionKit/Extensions/"
            + "TGOnDeviceInferenceProviderService.appex/Contents/MacOS/x").form, .appExtension)
        XCTAssertEqual(BundleShape.of(path: "/System/Library/DriverExtensions/"
            + "AppleCentauriAlpha.dext/AppleCentauriAlpha").form, .driverExtension)
        XCTAssertEqual(BundleShape.of(path: "/Applications/Thing.app/Contents/XPCServices/"
            + "Helper.xpc/Contents/MacOS/Helper").form, .xpcService)
        XCTAssertEqual(BundleShape.of(path: "/System/Library/PrivateFrameworks/"
            + "SkyLight.framework/Resources/WindowServer").form, .frameworkHelper)
    }

    func testAnAppExtensionInsideAnAppNamesTheAppItExtends() {
        let s = BundleShape.of(path: "/Applications/Thing.app/Contents/PlugIns/"
                                   + "ThingWidget.appex/Contents/MacOS/ThingWidget")
        XCTAssertEqual(s.form, .appExtension)
        XCTAssertEqual(s.containerName, "Thing")
    }

    func testABareExecutableHasNoBundleAndNoContainer() {
        let s = BundleShape.of(path: "/usr/libexec/duetexpertd")
        XCTAssertEqual(s.form, .executable)
        XCTAssertNil(s.bundlePath)
        XCTAssertNil(s.containerName)
    }

    // ── Apple's own words ───────────────────────────────────────────────────

    /// mdoc's `.Nd` field is the right answer when a page has one. This is the
    /// text of `/usr/share/man/man8/biomesyncd.8` as macOS ships it.
    func testTheNdFieldIsUsedWhenThePageHasOne() {
        let page = """
        .\\" Copyright (c) 2020 Apple Inc. All rights reserved.
        .Dd November 12, 2020
        .Dt biomesyncd 8
        .Os Darwin
        .Sh NAME
        .Nm biomesyncd
        .Nd data synchronization daemon
        .Sh DESCRIPTION
        .Nm
        synchronizes data between devices registered to the same account.
        """
        XCTAssertEqual(ManPage.parse(page, name: "biomesyncd"), "data synchronization daemon")
    }

    /// `duetexpertd` — the exact case that makes the DESCRIPTION fallback worth
    /// writing. It has no `.Nd` at all, and its DESCRIPTION is a sentence whose
    /// subject is the `.Nm` macro, so it is useless unless `.Nm` is expanded.
    func testADescriptionSentenceIsUsedWhenThereIsNoNdField() {
        let page = """
        .\\""Copyright (c) 2023 Apple Computer, Inc. All Rights Reserved.
        .Dd September 20th, 2023
        .Dt DUETEXPERTD 8
        .Os "Mac OS X"
        .Sh NAME
        .Nm duetexpertd
        .Sh SYNOPSIS
        .Nm
        .Sh DESCRIPTION
        .Nm
        powers personalized system experiences.
        .Pp
        There are no configuration options for this service.
        """
        XCTAssertEqual(ManPage.parse(page, name: "duetexpertd"),
                       "duetexpertd powers personalized system experiences.")
    }

    func testOnlyTheFirstSentenceOfADescriptionIsKept() {
        let page = """
        .Sh DESCRIPTION
        .Nm
        does one thing.
        It also does a second thing that will not fit in an inspector row.
        """
        XCTAssertEqual(ManPage.parse(page, name: "toold"), "toold does one thing.")
    }

    func testRoffEscapesAreStrippedRatherThanShownToTheUser() {
        let page = ".Sh NAME\n.Nd the \\fBfast\\fR path \\- always\n"
        XCTAssertEqual(ManPage.parse(page, name: "toold"), "the fast path - always")
    }

    /// A page whose description is nothing but the tool's own name says nothing.
    /// "duetexpertd: duetexpertd" is worse than showing the structural facts,
    /// because it looks like an answer.
    func testAPageThatOnlyRepeatsTheNameIsRejected() {
        XCTAssertNil(ManPage.parse(".Sh NAME\n.Nd toold\n", name: "toold"))
        XCTAssertNil(ManPage.parse(".Sh NAME\n.Nd Toold\n", name: "toold"))
    }

    func testAPageWithNeitherFieldDescribesNothing() {
        XCTAssertNil(ManPage.parse(".Dd today\n.Dt TOOLD 8\n.Sh SYNOPSIS\n.Nm\n", name: "toold"))
        XCTAssertNil(ManPage.parse("", name: "toold"))
    }

    /// Man pages are looked up by BASENAME, and a basename is not an identity.
    /// Without this gate a user's `~/bin/mds` would inherit Apple's description of
    /// Spotlight's metadata server — the same class of error as handing an SMC key
    /// its neighbour's label.
    func testOnlySIPProtectedBinariesMayInheritAManPage() {
        XCTAssertTrue(ManPage.describes(executableAt: "/usr/libexec/duetexpertd"))
        XCTAssertTrue(ManPage.describes(executableAt: "/System/Library/CoreServices/logind"))
        XCTAssertTrue(ManPage.describes(executableAt: "/sbin/launchd"))
        XCTAssertFalse(ManPage.describes(executableAt: "/usr/local/bin/mds"))
        XCTAssertFalse(ManPage.describes(executableAt: "/Users/someone/bin/mds"))
        XCTAssertFalse(ManPage.describes(executableAt: "/Applications/Thing.app/Contents/MacOS/mds"))
        XCTAssertFalse(ManPage.describes(executableAt: ""))
    }

    // ── The curated table ───────────────────────────────────────────────────

    func testAPathFamilyDescribesEverythingUnderIt() {
        let dext = ProcessCatalog.curated(
            forExecutablePath: "/System/Library/DriverExtensions/AppleCentauriAlpha.dext/AppleCentauriAlpha")
        XCTAssertNotNil(dext)
        XCTAssertTrue(dext!.contains("DriverKit"), dext!)
    }

    /// Longest prefix wins, so a narrow family is never swallowed by a broad one.
    func testTheMostSpecificPathFamilyWins() {
        let rosetta = ProcessCatalog.curated(forExecutablePath: "/usr/libexec/rosetta/oahd")
        XCTAssertEqual(rosetta, ProcessCatalog.pathFamilies
            .first { $0.prefix == "/usr/libexec/rosetta/" }?.text)
    }

    /// Keyed by absolute path, never by name: anyone can build a binary called
    /// `dasd`, but only Apple's installer can put one at `/usr/libexec/dasd`.
    func testACuratedBinaryIsKeyedByPathNotByName() {
        XCTAssertNotNil(ProcessCatalog.curated(forExecutablePath: "/usr/libexec/dasd"))
        XCTAssertNil(ProcessCatalog.curated(forExecutablePath: "/Users/someone/bin/dasd"))
    }

    /// The point of the whole feature: an executable nothing on this machine
    /// describes gets NO description. 64 of the binaries running here are exactly
    /// this — bare system daemons with no man page, no bundle, and no descriptive
    /// field anywhere in their launchd job.
    func testAnUndescribedBinaryInventsNothing() {
        let (purpose, source) = ProcessExplainer.describe(
            path: "/usr/libexec/nosuchdaemonanywhere", bundle: .empty)
        XCTAssertNil(purpose)
        XCTAssertNil(source)
    }

    /// A bundle display name is used only when it says something the process name
    /// does not. "TGOnDeviceInferenceProviderService is called
    /// TGOnDeviceInferenceProviderService" is not a description.
    func testABundleNameThatRepeatsTheExecutableIsNotADescription() {
        let echo = BundleFacts(identifier: "com.x.y", displayName: "Thing",
                               copyright: nil, extensionPoint: nil, executableName: "Thing")
        let (repeated, _) = ProcessExplainer.describe(path: "/opt/x/Thing.app/Contents/MacOS/Thing",
                                                     bundle: echo)
        XCTAssertNil(repeated)

        // The case worth keeping: a process called `Electron` whose bundle says it
        // is Visual Studio Code.
        let real = BundleFacts(identifier: "com.microsoft.VSCode", displayName: "Code",
                               copyright: nil, extensionPoint: nil, executableName: "Electron")
        let (used, source) = ProcessExplainer.describe(
            path: "/opt/x/Visual Studio Code.app/Contents/MacOS/Electron", bundle: real)
        XCTAssertEqual(used, "Code")
        XCTAssertEqual(source, .bundleName)
    }

    /// A bundle's name describes the bundle's OWN main executable and nothing else
    /// underneath it. `/Applications/Xcode.app/…/usr/bin/xctest` is inside
    /// Xcode.app and is not Xcode — this is the first thing the explainer got
    /// wrong when it was run against a real pid, and it is exactly the shape of
    /// mistake the whole file is arranged to avoid.
    func testABinaryBuriedInSomeoneElsesBundleDoesNotInheritItsName() {
        let xcode = BundleFacts(identifier: "com.apple.dt.Xcode", displayName: "Xcode",
                                copyright: nil, extensionPoint: nil, executableName: "Xcode")
        let (purpose, source) = ProcessExplainer.describe(
            path: "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest", bundle: xcode)
        XCTAssertNil(purpose)
        XCTAssertNil(source)
    }

    // ── launchd jobs ────────────────────────────────────────────────────────

    /// `KeepAlive` is a bool OR a dictionary of conditions, and they mean
    /// different things: "it will come back" versus "it will come back if it
    /// crashes". Collapsing them would state one as the other.
    func testKeepAliveIsReadAsAlwaysOrConditionallyAndNeverBoth() {
        let always = LaunchdIndex.parse(["Label": "com.apple.dasd",
                                         "Program": "/usr/libexec/dasd",
                                         "KeepAlive": true],
                                        isAgent: false, plistPath: "/x.plist")
        XCTAssertEqual(always?.job.alwaysRestarts, true)
        XCTAssertEqual(always?.job.conditionallyRestarts, false)

        let onCrash = LaunchdIndex.parse(["Label": "com.apple.bluetoothd",
                                          "Program": "/usr/sbin/bluetoothd",
                                          "KeepAlive": ["SuccessfulExit": false]],
                                         isAgent: false, plistPath: "/x.plist")
        XCTAssertEqual(onCrash?.job.alwaysRestarts, false)
        XCTAssertEqual(onCrash?.job.conditionallyRestarts, true)

        let onDemand = LaunchdIndex.parse(["Label": "com.apple.tipsd",
                                           "Program": "/usr/libexec/tipsd"],
                                          isAgent: false, plistPath: "/x.plist")
        XCTAssertEqual(onDemand?.job.alwaysRestarts, false)
        XCTAssertEqual(onDemand?.job.conditionallyRestarts, false)
    }

    func testAJobWithoutAProgramIsSkippedRatherThanIndexedUnderNothing() {
        // Indexing it under "" would make every process with no executable path —
        // the kernel among them — match whichever such job was read last.
        XCTAssertNil(LaunchdIndex.parse(["Label": "com.apple.something"],
                                        isAgent: false, plistPath: "/x.plist"))
        XCTAssertNil(LaunchdIndex.parse(["Label": "com.apple.something", "Program": ""],
                                        isAgent: false, plistPath: "/x.plist"))
        XCTAssertNil(LaunchdIndex.parse(["Program": "/usr/libexec/x"],
                                        isAgent: false, plistPath: "/x.plist"))
    }

    func testTheProgramComesFromProgramArgumentsWhenProgramIsAbsent() {
        let job = LaunchdIndex.parse(["Label": "com.apple.mDNSResponder.reloaded",
                                      "ProgramArguments": ["/usr/sbin/mDNSResponder"],
                                      "MachServices": ["com.apple.dnssd.service": true,
                                                       "com.apple.mDNSResponder.control": true]],
                                     isAgent: false, plistPath: "/x.plist")
        XCTAssertEqual(job?.program, "/usr/sbin/mDNSResponder")
        XCTAssertEqual(job?.job.machServices,
                       ["com.apple.dnssd.service", "com.apple.mDNSResponder.control"])
    }

    // ── This machine ────────────────────────────────────────────────────────

    /// End to end against the one process guaranteed to exist and to be ours.
    func testOurOwnProcessExplainsWithoutInventingAnything() {
        guard let d = ProcessInspector.details(for: getpid()) else {
            return XCTFail("we must be able to read ourselves")
        }
        let x = ProcessExplainer.explain(d)
        XCTAssertEqual(x.pid, getpid())
        XCTAssertEqual(x.safety.verdict, .isSelf)
        XCTAssertEqual(x.domain, InstallDomain.of(path: d.executablePath))
        // The headline is assembled from facts that were read, so every clause it
        // contains has to correspond to one.
        XCTAssertTrue(x.headline.hasPrefix(x.form.text), x.headline)
        if x.origin == .unknown { XCTAssertFalse(x.headline.contains("signed by")) }
        // A purpose, if there is one, must have a source. A sentence with no
        // provenance is exactly what must not happen.
        if x.purpose != nil { XCTAssertNotNil(x.purposeSource) }
        if x.purpose == nil { XCTAssertNil(x.purposeSource) }
    }

    /// The end-to-end claim, against real daemons on the real machine: a known
    /// system daemon is described in Apple's own words, is verified as Apple's,
    /// and is placed correctly.
    ///
    /// `ProcessInspector.details` is same-uid only, so a root daemon cannot be
    /// reached through a pid at all — these go through the path, which is what
    /// every expensive part of the explainer keys on anyway.
    func testKnownSystemDaemonsAreDescribedInApplesOwnWords() throws {
        // Both ship a man page, and they exercise the two different shapes of it:
        // `biomesyncd` has an `.Nd` field, `duetexpertd` has only a DESCRIPTION
        // whose subject is the `.Nm` macro.
        let daemons = ["/usr/libexec/biomesyncd", "/usr/libexec/duetexpertd", "/bin/ls"]
            .filter { FileManager.default.fileExists(atPath: $0) }
        try XCTSkipIf(daemons.isEmpty, "none of the sampled system binaries exist here")

        for path in daemons {
            let (purpose, source) = ProcessExplainer.describe(path: path, bundle: .empty)
            let name = (path as NSString).lastPathComponent
            XCTAssertEqual(source, .manPage, name)
            let text = try XCTUnwrap(purpose, name)
            XCTAssertFalse(text.isEmpty, name)
            XCTAssertNotEqual(text.lowercased(), name.lowercased(),
                              "a description that is only the tool's name is not a description")
            XCTAssertEqual(CodeSignature.origin(ofExecutableAt: path), .apple, name)
            XCTAssertEqual(InstallDomain.of(path: path), .systemBinaries, name)
        }
    }

    /// The other half, and the one that matters more: a system daemon nothing on
    /// this machine documents gets NO sentence. `bluetoothd` and `textcontextd`
    /// are both real, both Apple's, both running right now, and neither has a man
    /// page, a bundle, or a descriptive field in its launchd job.
    func testUndocumentedSystemDaemonsGetStructureAndNoInventedPurpose() throws {
        let daemons = ["/usr/sbin/bluetoothd", "/usr/libexec/textcontextd"]
            .filter { FileManager.default.fileExists(atPath: $0) }
        try XCTSkipIf(daemons.isEmpty, "none of the sampled system binaries exist here")

        for path in daemons {
            let (purpose, source) = ProcessExplainer.describe(path: path, bundle: .empty)
            XCTAssertNil(purpose, "\(path) has no local source and must not acquire one")
            XCTAssertNil(source)
            // The structure is still there, and it is a real answer to "is this
            // Apple's and why is it running".
            XCTAssertEqual(CodeSignature.origin(ofExecutableAt: path), .apple)
            XCTAssertEqual(InstallDomain.of(path: path), .systemBinaries)
        }
    }

    /// The signature check is a real cryptographic verification against Apple's
    /// anchor, not a string comparison against a certificate subject — a subject
    /// can say anything.
    func testAnApplePlatformBinaryVerifiesAgainstApplesAnchor() throws {
        guard FileManager.default.fileExists(atPath: "/bin/ls") else {
            throw XCTSkip("no /bin/ls")
        }
        XCTAssertEqual(CodeSignature.origin(ofExecutableAt: "/bin/ls"), .apple)
    }

    func testAMissingFileHasAnUnknownOriginRatherThanAnUnsignedOne() {
        // "We could not read it" and "it carries no signature" are different
        // facts, and only one of them is an accusation.
        XCTAssertEqual(CodeSignature.origin(ofExecutableAt: "/usr/libexec/nosuchbinary"), .unknown)
        XCTAssertEqual(CodeSignature.origin(ofExecutableAt: ""), .unknown)
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/// Whether quitting something is sensible — derived from facts, never asserted.
///
/// Driven entirely with synthetic processes. NOTHING here signals anything: the
/// derivation is deliberately a pure function precisely so that the part which
/// has to be right can be tested without `kill(2)` anywhere near it.
final class QuitSafetyTests: XCTestCase {

    private let me: uid_t = 501
    private let selfPID: pid_t = 4242

    private func safety(pid: pid_t = 10,
                        uid: uid_t? = nil,
                        owner: String = "noah",
                        form: ProcessForm = .executable,
                        container: String? = nil,
                        job: LaunchdJob? = nil,
                        parentIsLaunchd: Bool = false) -> QuitSafety {
        QuitSafety.of(pid: pid, uid: uid ?? me, owner: owner, form: form,
                      containerName: container, job: job, parentIsLaunchd: parentIsLaunchd,
                      currentUID: me, selfPID: selfPID)
    }

    private func job(_ label: String, always: Bool = false, conditional: Bool = false) -> LaunchdJob {
        LaunchdJob(label: label, isAgent: false, alwaysRestarts: always,
                   conditionallyRestarts: conditional, machServices: [],
                   plistPath: "/System/Library/LaunchDaemons/\(label).plist")
    }

    func testAnodeNeverOffersToQuitItself() {
        let s = safety(pid: selfPID)
        XCTAssertEqual(s.verdict, .isSelf)
        XCTAssertEqual(s.answer, "No")
        XCTAssertTrue(s.detail.contains("Anode"), s.detail)
    }

    /// A root-owned process fails with EPERM, so the honest answer is that no
    /// button exists — not that quitting is risky.
    func testARootOwnedProcessSaysWhyItCannotBeSignalledAtAll() {
        let s = safety(uid: 0, owner: "root")
        XCTAssertEqual(s.verdict, .notPermitted)
        XCTAssertTrue(s.detail.contains("root"), s.detail)
        XCTAssertTrue(s.detail.contains("unprivileged"), s.detail)
    }

    /// Ownership outranks everything after it: a root-owned launchd daemon must
    /// report the EPERM wall, not "it will come back", because the user will
    /// never get far enough for the second to matter.
    func testOwnershipIsDecidedBeforeAnythingElse() {
        let s = safety(uid: 0, owner: "root", job: job("com.apple.dasd", always: true))
        XCTAssertEqual(s.verdict, .notPermitted)
    }

    func testAnAppIsWarnedAboutUnsavedWork() {
        let s = safety(form: .application)
        XCTAssertEqual(s.verdict, .mayHaveUnsavedWork)
        XCTAssertTrue(s.detail.lowercased().contains("unsaved"), s.detail)
        // The two verbs differ in exactly the way that matters here.
        XCTAssertTrue(s.detail.contains("Force Quit"), s.detail)
    }

    /// Killing one renderer of a browser is not the same act as quitting the
    /// browser, and the sentence has to name the thing that will break.
    func testAHelperPointsAtWhatItBelongsTo() {
        let s = safety(form: .application, container: "Brave Browser")
        XCTAssertEqual(s.verdict, .partOfSomethingElse)
        XCTAssertTrue(s.detail.contains("Brave Browser"), s.detail)
    }

    func testAlwaysRestartedJobsSayTheyComeBackImmediately() {
        let s = safety(job: job("com.apple.dasd", always: true))
        XCTAssertEqual(s.verdict, .respawns)
        XCTAssertTrue(s.detail.contains("com.apple.dasd"), s.detail)
        XCTAssertTrue(s.detail.contains("KeepAlive"), s.detail)
    }

    /// "It will come back" and "it will come back if it crashes" are different
    /// answers, so a conditional `KeepAlive` must not borrow the unconditional
    /// sentence.
    func testAConditionalKeepAliveIsNotReportedAsUnconditional() {
        let s = safety(job: job("com.apple.bluetoothd", conditional: true))
        XCTAssertEqual(s.verdict, .respawns)
        XCTAssertFalse(s.detail.contains("immediately"), s.detail)
        XCTAssertTrue(s.detail.contains("conditions"), s.detail)
    }

    func testAnOnDemandJobSaysItReturnsWhenSomethingAsksForIt() {
        let s = safety(job: job("com.apple.tipsd"))
        XCTAssertEqual(s.verdict, .respawns)
        XCTAssertTrue(s.detail.contains("asks for it"), s.detail)
    }

    /// Most Apple services are launched through XPC definitions embedded in
    /// frameworks, with no job file in the standard folders at all. Reporting
    /// "it will not come back" for those would be reading absence of evidence as
    /// evidence of absence.
    func testAProcessLaunchdParentedButWithNoJobFileSaysSoOutLoud() {
        let s = safety(parentIsLaunchd: true)
        XCTAssertEqual(s.verdict, .respawns)
        XCTAssertTrue(s.detail.contains("No job file"), s.detail)
        XCTAssertTrue(s.detail.contains("cannot read"), s.detail)
    }

    func testAnOrdinaryProcessGetsAPlainYes() {
        let s = safety()
        XCTAssertEqual(s.verdict, .ordinary)
        XCTAssertEqual(s.answer, "Yes")
    }

    func testTheKernelCannotBeSignalled() {
        // pid 0 is `kernel_task`, and it is ours by uid, so nothing before this
        // rule would have caught it.
        let s = safety(pid: 0, form: .kernel)
        XCTAssertEqual(s.verdict, .notPermitted)
        XCTAssertTrue(s.detail.contains("kernel"), s.detail)
    }

    /// The sentence and the button are decided by ONE predicate, and this is what
    /// makes that claim more than an intention. A "safe to quit" line that
    /// disagrees with the enabled state of the control beside it is worse than
    /// either being wrong alone — it makes the app look like it is hiding
    /// something.
    func testTheSafetyLineAndTheQuitButtonCanNeverDisagree() {
        let cases: [(pid_t, uid_t)] = [(10, 501), (11, 0), (12, 88), (selfPID, 501), (0, 501)]
        for (pid, uid) in cases {
            let plan = ProcessActions.plan(
                for: [ProcessActions.Candidate(pid: pid, uid: uid, owner: "x")],
                currentUID: me, selfPID: selfPID)
            let s = safety(pid: pid, uid: uid, form: pid == 0 ? .kernel : .executable)
            let offered = plan.canAct
            let claimed = s.verdict != .isSelf && s.verdict != .notPermitted
            XCTAssertEqual(offered, claimed,
                           "pid \(pid) uid \(uid): button says \(offered), sentence says \(claimed)")
        }
    }

    /// `kill(2)` reads non-positive pids as BROADCASTS: 0 is our whole process
    /// group, -1 is every process this user may signal. pid 0 is not
    /// hypothetical — it is `kernel_task`, and it appears in process listings
    /// like anything else.
    ///
    /// Only the predicate is exercised. Calling the signalling path to prove the
    /// guard works would mean arranging for the failure case to SIGKILL the test
    /// runner's process group.
    func testNonPositivePidsAreNeverSignalTargets() {
        XCTAssertFalse(ProcessControl.isSignalable(0))
        XCTAssertFalse(ProcessControl.isSignalable(-1))
        XCTAssertFalse(ProcessControl.isSignalable(-getpid()))
        XCTAssertFalse(ProcessControl.isSignalable(getpid()))
        XCTAssertTrue(ProcessControl.isSignalable(getpid() == 1 ? 2 : 1))
    }
}
