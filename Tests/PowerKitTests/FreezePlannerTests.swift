import XCTest
@testable import PowerKit

/// Which process is in which pile for Ultra Low Power Mode. Everything here is a made-up list of processes: the rule is
/// pure, so nothing is read from the Mac and nothing is signalled.
final class FreezePlannerTests: XCTestCase {

    private let user: uid_t = 501

    // ── Fixtures ────────────────────────────────────────────────────────────

    /// A process with ids made up for the test. The start time follows the pid so two processes never look alike.
    private func proc(_ pid: pid_t, parent: pid_t = 1, uid: uid_t = 501, path: String = "", responsible: pid_t? = nil,
                      app: AppKind = .none, bundle: String? = nil, name: String? = nil, label: String? = nil,
                      team: String? = nil, tap: Bool = false, mic: Bool = false) -> UltraProcess {
        let leaf = path.split(separator: "/").last.map(String.init) ?? "p\(pid)"
        return UltraProcess(pid: pid, parent: parent, uid: uid, startTime: UInt64(pid) * 10, path: path,
                            responsible: responsible, app: app, bundleID: bundle, name: name ?? leaf,
                            launchdLabel: label, team: team, ownsEventTap: tap, usesMicOrCamera: mic)
    }

    private func app(_ pid: pid_t, _ id: String, _ name: String, kind: AppKind = .regular, parent: pid_t = 1,
                     responsible: pid_t? = nil, team: String? = nil, uid: uid_t = 501, tap: Bool = false,
                     mic: Bool = false) -> UltraProcess {
        proc(pid, parent: parent, uid: uid, path: "/Applications/\(name).app/Contents/MacOS/\(name)",
             responsible: responsible, app: kind, bundle: id, name: name, team: team, tap: tap, mic: mic)
    }

    private func editor(_ pid: pid_t = 10) -> UltraProcess { app(pid, "com.example.editor", "Editor") }
    private func browser(_ pid: pid_t = 20) -> UltraProcess { app(pid, "com.example.browser", "Browser") }

    private func plan(_ processes: [UltraProcess], front: pid_t? = nil, alwaysKeep: Set<String> = [],
                      ownPIDs: Set<pid_t> = []) -> FreezePlan {
        FreezePlanner.plan(processes: processes, user: user, front: front, alwaysKeep: alwaysKeep, ownPIDs: ownPIDs)
    }

    private func additions(_ processes: [UltraProcess], frozen: Set<String>, known: Set<pid_t> = [],
                           ownPIDs: Set<pid_t> = []) -> [FreezeGroup] {
        FreezePlanner.additions(processes: processes, user: user, frozenGroups: frozen, known: known, ownPIDs: ownPIDs)
    }

    private func ids(_ groups: [FreezeGroup]) -> [String] { groups.map(\.id) }

    private func pids(_ groups: [FreezeGroup], _ id: String) -> [pid_t] {
        groups.first { $0.id == id }?.members.map(\.pid) ?? []
    }

    private func assertNowhere(_ p: FreezePlan, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(p.kept.isEmpty, "kept: \(p.kept)", file: file, line: line)
        XCTAssertTrue(p.frozen.isEmpty, "frozen: \(p.frozen)", file: file, line: line)
        XCTAssertTrue(p.leftRunning.isEmpty, "leftRunning: \(p.leftRunning)", file: file, line: line)
    }

    // ── The front app and what belongs to it ────────────────────────────────

    func testTheFrontAppAndItsTerminalToolsAreKept() {
        let list = [editor(),
                    proc(11, parent: 10, path: "/bin/zsh"),                       // the terminal's shell, in a system place
                    proc(12, parent: 11, path: "/opt/tools/bin/lint"),        // a tool run from that shell
                    browser()]
        let p = plan(list, front: 10)
        XCTAssertEqual(ids(p.kept), ["com.example.editor"])
        XCTAssertEqual(pids(p.kept, "com.example.editor"), [10, 11, 12])
        XCTAssertEqual(ids(p.frozen), ["com.example.browser"])
        XCTAssertTrue(p.leftRunning.isEmpty)
    }

    func testAnotherAppIsFrozenWholeWithItsHelpers() {
        let list = [editor(),
                    browser(),
                    proc(21, parent: 20, path: "/Applications/Browser.app/Contents/Frameworks/Browser Helper.app/Contents/MacOS/Browser Helper"),
                    proc(22, parent: 1, path: "/Applications/Browser.app/Contents/XPCServices/Net.xpc/Contents/MacOS/Net")]  // launchd's child, only the path ties it
        let p = plan(list, front: 10)
        XCTAssertEqual(ids(p.frozen), ["com.example.browser"])
        XCTAssertEqual(pids(p.frozen, "com.example.browser"), [20, 21, 22])
        XCTAssertEqual(p.frozen.first?.name, "Browser")
        XCTAssertEqual(p.frozen.first?.members.map(\.startTime), [200, 210, 220])
    }

    func testASystemLocatedHelperBelongsToTheAppResponsibleForIt() {
        let webContent = "/System/Library/PrivateFrameworks/Net.framework/Versions/A/XPCServices/NetWorker.xpc/Contents/MacOS/NetWorker"
        let list = [editor(), browser(),
                    proc(30, parent: 1, path: webContent, responsible: 20),    // belongs to the browser: frozen with it
                    proc(31, parent: 1, path: "/usr/libexec/prefsd")]        // serves everyone: never frozen
        let p = plan(list, front: 10)
        XCTAssertEqual(ids(p.frozen), ["com.example.browser"])
        XCTAssertEqual(pids(p.frozen, "com.example.browser"), [20, 30])
    }

    func testAppleAppsTheOwnerOpenedAreFrozen() {
        let mail = proc(40, path: "/System/Applications/Mail.app/Contents/MacOS/Mail", app: .regular,
                        bundle: "com.apple.mail", name: "Mail")
        let p = plan([editor(), mail], front: 10)
        XCTAssertEqual(ids(p.frozen), ["com.apple.mail"])
        XCTAssertEqual(p.frozen.first?.name, "Mail")
    }

    func testSystemServicesAreNeverFrozen() {
        let list = [editor(),
                    proc(41, path: "/usr/libexec/x"),
                    proc(42, path: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter",
                         app: .accessory, bundle: "com.apple.controlcenter", name: "ControlCenter"),
                    proc(43, path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",
                         app: .regular, bundle: "com.apple.finder", name: "Finder"),
                    proc(44, path: "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock",
                         app: .accessory, bundle: "com.apple.dock", name: "Dock")]
        let p = plan(list, front: 10)
        XCTAssertEqual(ids(p.frozen), [])
        XCTAssertEqual(ids(p.kept), ["com.example.editor"])
        XCTAssertTrue(p.leftRunning.isEmpty)
    }

    func testIsSystemRules() {
        for root in ["/System/x", "/usr/libexec/x", "/bin/zsh", "/sbin/launchd", "/Library/Apple/usr/libexec/x"] {
            XCTAssertTrue(FreezePlanner.isSystem(proc(1, path: root)), root)
        }
        XCTAssertFalse(FreezePlanner.isSystem(proc(1, path: "/opt/tools/bin/x")))
        XCTAssertFalse(FreezePlanner.isSystem(proc(1, path: "/Users/me/bin/x")))
        // An app is not system because of where its file is: the first sort put Apple's developer tools in the wrong pile.
        XCTAssertFalse(FreezePlanner.isSystem(proc(1, path: "/System/Applications/Mail.app/Contents/MacOS/Mail",
                                                   app: .regular, bundle: "com.apple.mail")))
        XCTAssertFalse(FreezePlanner.isSystem(proc(1, path: "/System/x", app: .accessory, bundle: "com.example.agent")))
        XCTAssertTrue(FreezePlanner.isSystem(proc(1, path: "/Applications/X.app/x", app: .accessory, bundle: "com.apple.controlcenter")))
        XCTAssertFalse(FreezePlanner.isSystem(proc(1, path: "/Applications/X.app/x", app: .regular, bundle: "com.apple.mail")))
        // The three the line is drawn around, whatever kind macOS calls them.
        for id in ["com.apple.finder", "com.apple.dock", "com.apple.loginwindow"] {
            for kind in [AppKind.regular, .accessory, .none] {
                XCTAssertTrue(FreezePlanner.isSystem(proc(1, path: "/Applications/X.app/x", app: kind, bundle: id)), "\(id) \(kind)")
            }
        }
    }

    func testOtherUsersProcessesAreNeverFrozen() {
        let list = [editor(),
                    proc(50, uid: 0, path: "/Library/PrivilegedHelperTools/com.example.root"),
                    app(52, "com.example.other", "Other", uid: 502),                       // another user's app
                    proc(53, parent: 52, uid: 502, path: "/Applications/Other.app/Contents/MacOS/Helper"),
                    proc(54, parent: 50, uid: 501, path: "/opt/tools/bin/tool")]         // the user's, but started by a root process
        let p = plan(list, front: 10)
        XCTAssertTrue(p.frozen.isEmpty)
        XCTAssertTrue(p.leftRunning.isEmpty)
        XCTAssertEqual(ids(p.kept), ["com.example.editor"])
    }

    func testAnodeAndItsHelpersAreNeverFrozen() {
        let list = [editor(), browser(),
                    app(90, "com.example.anode", "Anode"),
                    proc(91, parent: 90, path: "/Applications/Anode.app/Contents/MacOS/watchdog"),
                    proc(92, parent: 90, path: "/bin/ps")]                  // a child nobody listed: still Anode's
        let p = plan(list, front: 10, ownPIDs: [90, 91])
        XCTAssertEqual(ids(p.frozen), ["com.example.browser"])
        XCTAssertEqual(ids(p.kept), ["com.example.editor"])
        XCTAssertTrue(p.leftRunning.isEmpty)
    }

    func testAnodeStartedFromAnotherAppDoesNotProtectThatApp() {
        // Started from the browser's shell, so macOS holds the browser responsible for it. Anode is never a member, the
        // browser is frozen without it.
        let list = [editor(), browser(),
                    proc(90, parent: 20, path: "/Users/me/Anode/.build/debug/anode", responsible: 20, app: .regular,
                         bundle: "com.example.anode", name: "Anode")]
        let p = plan(list, front: 10, ownPIDs: [90])
        XCTAssertEqual(pids(p.frozen, "com.example.browser"), [20])
    }

    func testAnEventTapOwnerKeepsItsWholeGroupRunning() {
        let list = [editor(),
                    app(60, "com.example.remapper", "Remapper"),
                    proc(61, parent: 60, path: "/Applications/Remapper.app/Contents/Library/Remapper Agent", tap: true),
                    browser()]
        let p = plan(list, front: 10)
        XCTAssertEqual(ids(p.frozen), ["com.example.browser"])               // the tap is on a helper; the app stays too
        XCTAssertTrue(p.leftRunning.isEmpty)
        XCTAssertEqual(ids(p.kept), ["com.example.editor"])
    }

    // ── A part Anode cannot stop (rule 7) ───────────────────────────────────

    func testAnAppWithARootCompanionOfTheSameTeamIsLeftRunning() {
        let list = [editor(),
                    proc(70, path: "/Users/me/Library/Application Support/Sync/syncd", app: .none, label: "com.example.sync.user",
                         team: "T1"),
                    proc(71, parent: 70, path: "/Users/me/Library/Application Support/Sync/uploader", team: "T1"),
                    proc(72, uid: 0, path: "/Library/PrivilegedHelperTools/com.example.sync.root", team: "T1")]
        let p = plan(list, front: 10)
        XCTAssertEqual(ids(p.leftRunning), ["job:com.example.sync.user"])
        XCTAssertEqual(pids(p.leftRunning, "job:com.example.sync.user"), [70, 71])   // what would have been frozen
        XCTAssertTrue(p.frozen.isEmpty)
    }

    func testARootProcessInsideTheSameBundleProtectsTheGroup() {
        let list = [editor(),
                    app(80, "com.example.sync", "Sync"),
                    proc(81, uid: 0, path: "/Applications/Sync.app/Contents/Library/LaunchServices/com.example.sync.root")]
        let p = plan(list, front: 10)
        XCTAssertEqual(ids(p.leftRunning), ["com.example.sync"])
        XCTAssertTrue(p.frozen.isEmpty)
    }

    func testARootProcessInsideAnOuterBundleProtectsTheGroupOfAnInnerHelper() {
        // The user's helper sits in a bundle inside the bundle the root process lives in.
        let list = [editor(),
                    proc(80, path: "/Applications/Suite.app/Contents/Applications/Tool.app/Contents/MacOS/Tool", app: .regular,
                         bundle: "com.example.tool", name: "Tool"),
                    proc(81, uid: 0, path: "/Applications/Suite.app/Contents/MacOS/suited")]
        XCTAssertEqual(ids(plan(list, front: 10).leftRunning), ["com.example.tool"])
    }

    func testARootProcessOfAnotherTeamProtectsNothing() {
        let list = [editor(),
                    app(80, "com.example.sync", "Sync", team: "T1"),
                    proc(81, uid: 0, path: "/Library/PrivilegedHelperTools/com.example.other.root", team: "T2")]
        let p = plan(list, front: 10)
        XCTAssertEqual(ids(p.frozen), ["com.example.sync"])
        XCTAssertTrue(p.leftRunning.isEmpty)
    }

    func testSystemRootServicesDoNotProtectAnApp() {
        // The system's own code has no team: nil never matches nil.
        let list = [editor(),
                    app(80, "com.example.sync", "Sync"),
                    proc(81, uid: 0, path: "/usr/libexec/policyd"),
                    proc(82, uid: 0, path: "/System/Library/CoreServices/Helper.app/Contents/MacOS/Helper"),
                    proc(83, uid: 0, path: "")]
        let p = plan(list, front: 10)
        XCTAssertEqual(ids(p.frozen), ["com.example.sync"])
        XCTAssertTrue(p.leftRunning.isEmpty)
    }

    func testAProcessWithNoPathNeverSharesABundle() {
        let list = [editor(),
                    proc(80, path: "", app: .regular, bundle: "com.example.sync", name: "Sync"),
                    proc(81, uid: 0, path: "")]
        XCTAssertEqual(ids(plan(list, front: 10).frozen), ["com.example.sync"])
    }

    func testARootCompanionOfAKeptAppDoesNotMoveItOutOfKept() {
        let list = [app(80, "com.example.sync", "Sync", team: "T1"),
                    proc(81, uid: 0, path: "/Library/PrivilegedHelperTools/com.example.sync.root", team: "T1")]
        let p = plan(list, front: 80)
        XCTAssertEqual(ids(p.kept), ["com.example.sync"])
        XCTAssertTrue(p.leftRunning.isEmpty)
    }

    func testLeftRunningListsTheMembersThatWouldHaveBeenFrozen() {
        let list = [editor(),
                    app(80, "com.example.sync", "Sync"),
                    proc(81, parent: 80, path: "/Applications/Sync.app/Contents/PlugIns/Share.appex/Contents/MacOS/Share"),
                    proc(82, uid: 0, path: "/Applications/Sync.app/Contents/Library/LaunchServices/com.example.sync.root")]
        XCTAssertEqual(pids(plan(list, front: 10).leftRunning, "com.example.sync"), [80])
    }

    // ── Kept for a reason other than being in front ─────────────────────────

    func testAnAppUsingTheMicrophoneIsKeptAndListedAsKept() {
        let list = [editor(),
                    app(100, "com.example.calls", "Calls"),
                    proc(101, parent: 100, path: "/Applications/Calls.app/Contents/Helpers/Media", mic: true),
                    browser()]
        let p = plan(list, front: 10)
        XCTAssertEqual(ids(p.kept), ["com.example.calls", "com.example.editor"])
        XCTAssertEqual(pids(p.kept, "com.example.calls"), [100, 101])
        XCTAssertEqual(ids(p.frozen), ["com.example.browser"])
    }

    func testAlwaysKeepTakesAppsAndBackgroundTools() {
        let list = [editor(),
                    app(110, "com.example.vpn", "VPN"),
                    proc(111, path: "/opt/tools/dbserver/bin/dbserver", name: "dbserver", label: "homebrew.db"),
                    browser()]
        let p = plan(list, front: 10, alwaysKeep: ["com.example.vpn", "job:homebrew.db"])
        XCTAssertEqual(ids(p.kept), ["com.example.editor", "com.example.vpn", "job:homebrew.db"])
        XCTAssertEqual(ids(p.frozen), ["com.example.browser"])
    }

    func testAnEventTapOwnerThatIsInFrontIsStillNamedAsKept() {
        let list = [app(60, "com.example.remapper", "Remapper", tap: true), browser()]
        let p = plan(list, front: 60)
        XCTAssertEqual(ids(p.kept), ["com.example.remapper"])
        XCTAssertEqual(ids(p.frozen), ["com.example.browser"])
    }

    func testNoFrontAppStillPlans() {
        let list = [editor(), browser()]
        let p = plan(list, front: nil)
        XCTAssertTrue(p.kept.isEmpty)
        XCTAssertEqual(ids(p.frozen), ["com.example.browser", "com.example.editor"])
        XCTAssertEqual(ids(plan(list, front: 999).frozen), ["com.example.browser", "com.example.editor"])   // not in the list
    }

    func testASystemServiceUsingTheMicrophoneIsNotNamed() {
        let list = [editor(), proc(41, path: "/usr/libexec/speechd", mic: true)]
        let p = plan(list, front: 10)
        XCTAssertEqual(ids(p.kept), ["com.example.editor"])
    }

    func testTheFrontPidOfASystemServiceKeepsNothing() {
        let list = [editor(), proc(43, path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", app: .regular,
                                   bundle: "com.apple.finder", name: "Finder")]
        let p = plan(list, front: 43)
        XCTAssertTrue(p.kept.isEmpty)
        XCTAssertEqual(ids(p.frozen), ["com.example.editor"])
    }

    // ── Background tools with no app ────────────────────────────────────────

    func testABackgroundToolWithNoAppIsFrozenUnderItsJobName() {
        let list = [editor(),
                    proc(120, parent: 1, path: "/opt/tools/dbserver/bin/dbserver", name: "dbserver", label: "homebrew.db"),
                    proc(121, parent: 120, path: "/opt/tools/dbserver/bin/dbserver-writer", name: "dbserver-writer")]
        let p = plan(list, front: 10)
        XCTAssertEqual(ids(p.frozen), ["job:homebrew.db"])
        XCTAssertEqual(p.frozen.first?.name, "dbserver")
        XCTAssertEqual(pids(p.frozen, "job:homebrew.db"), [120, 121])
    }

    func testAToolWithNoLabelIsGroupedByExecutableName() {
        let list = [editor(),
                    proc(130, parent: 1, path: "/Users/me/proj/bin/devserver"),
                    proc(131, parent: 130, path: "/Users/me/proj/bin/devserver")]
        let p = plan(list, front: 10)
        XCTAssertEqual(ids(p.frozen), ["exe:devserver"])
        XCTAssertEqual(pids(p.frozen, "exe:devserver"), [130, 131])
    }

    func testAToolWithNoReadablePathAndNoAppIsLeftAlone() {
        // Nothing is known about it: it may be a system daemon whose path could not be read, and two unrelated ones of
        // the same name must not become one group.
        let list = [editor(), proc(130, parent: 1, path: "", name: "devserver"), proc(131, parent: 1, path: "", name: "devserver")]
        let p = plan(list, front: 10)
        XCTAssertTrue(p.frozen.isEmpty)
        XCTAssertTrue(p.leftRunning.isEmpty)
        XCTAssertEqual(ids(p.kept), ["com.example.editor"])
    }

    func testAProcessWithNoReadablePathStillBelongsToTheAppItIsTiedTo() {
        // Unknown only as an owner: tied to an app by `responsible` or by its parent, it is that app's member.
        let list = [editor(), browser(),
                    proc(21, parent: 1, path: "", responsible: 20),
                    proc(22, parent: 20, path: "")]
        let p = plan(list, front: 10)
        XCTAssertEqual(pids(p.frozen, "com.example.browser"), [20, 21, 22])
    }

    func testADetachedToolIsItsOwnGroupEvenWhenItsResponsibleIsItself() {
        // Started from the editor's terminal, then detached: parent 1 and responsible for itself.
        let list = [editor(), proc(12, parent: 1, path: "/Users/me/proj/tools/bin/devtool", responsible: 12)]
        let p = plan(list, front: 10)
        XCTAssertEqual(ids(p.frozen), ["exe:devtool"])
        XCTAssertEqual(pids(p.kept, "com.example.editor"), [10])
    }

    // ── Extensions ──────────────────────────────────────────────────────────

    func testExtensionsOfAFrozenAppAreLeftRunning() {
        let list = [editor(), browser(),
                    proc(141, parent: 1, path: "/Applications/Browser.app/Contents/PlugIns/Some.appex/Contents/MacOS/Some", responsible: 20)]
        let p = plan(list, front: 10)
        XCTAssertEqual(pids(p.frozen, "com.example.browser"), [20])
    }

    func testAGroupOfOnlyExtensionsIsNotListed() {
        let list = [editor(), proc(141, path: "/Users/me/Library/Some.appex/Contents/MacOS/Some")]
        XCTAssertTrue(plan(list, front: 10).frozen.isEmpty)
    }

    // ── How a process finds its owner ───────────────────────────────────────

    func testAResponsiblePidThatIsGoneFallsBackToTheParentChain() {
        let list = [editor(), browser(),
                    proc(21, parent: 20, path: "/bin/zsh", responsible: 999)]      // 999 has exited
        XCTAssertEqual(pids(plan(list, front: 10).frozen, "com.example.browser"), [20, 21])
    }

    func testAResponsiblePidOfOneOrItselfIsNotAnOwner() {
        let list = [editor(), browser(),
                    proc(21, parent: 20, path: "/bin/zsh", responsible: 21),
                    proc(22, parent: 20, path: "/bin/zsh", responsible: 1)]
        XCTAssertEqual(pids(plan(list, front: 10).frozen, "com.example.browser"), [20, 21, 22])
    }

    func testLoopsInTheChainsDoNotHang() {
        let list = [editor(),
                    proc(30, parent: 31, path: "/opt/a", responsible: 31),     // each held responsible by the other
                    proc(31, parent: 30, path: "/opt/b", responsible: 30),
                    proc(32, parent: 33, path: "/opt/c"),                      // each the other's parent
                    proc(33, parent: 32, path: "/opt/d")]
        let p = plan(list, front: 10)
        XCTAssertEqual(p.frozen.flatMap(\.members).map(\.pid).sorted(), [30, 31, 32, 33])
    }

    func testOwnerFollowsResponsibleOnToTheNextOwner() {
        // A helper is held to the app that started it, and that app was started from the editor's terminal.
        let list = [editor(),
                    app(20, "com.example.viewer", "Viewer", responsible: 10),
                    proc(21, parent: 1, path: "/System/Library/PrivilegedHelperTools/x", responsible: 20)]
        let p = plan(list, front: 10)
        XCTAssertTrue(p.frozen.isEmpty)
        XCTAssertEqual(ids(p.kept), ["com.example.editor"])
        XCTAssertEqual(pids(p.kept, "com.example.editor"), [10, 20, 21])
    }

    func testAToolRunFromInsideAnotherAppsBundleStaysWithItsParents() {
        // The command-line tool of a running app, run from the editor's shell: it is the editor's work, not that app's.
        let list = [editor(),
                    proc(11, parent: 10, path: "/bin/zsh"),
                    proc(12, parent: 11, path: "/Applications/Container.app/Contents/Resources/bin/container"),
                    app(50, "com.example.container", "Container")]
        let p = plan(list, front: 10)
        XCTAssertEqual(pids(p.kept, "com.example.editor"), [10, 11, 12])
        XCTAssertEqual(pids(p.frozen, "com.example.container"), [50])
    }

    func testAnAppInsideAnotherRunningAppsBundleBelongsToIt() {
        let list = [app(50, "com.example.suite", "Suite"),
                    proc(51, path: "/Applications/Suite.app/Contents/Applications/Tool.app/Contents/MacOS/Tool", app: .accessory,
                         bundle: "com.example.tool", name: "Tool"),
                    editor()]
        let p = plan(list, front: 10)
        XCTAssertEqual(ids(p.frozen), ["com.example.suite"])
        XCTAssertEqual(pids(p.frozen, "com.example.suite"), [50, 51])
    }

    func testAHelperOfAnInnerAppBelongsToItWhenTheOuterAppIsNotRunning() {
        let tool = proc(51, path: "/Applications/Suite.app/Contents/Applications/Tool.app/Contents/MacOS/Tool", app: .regular,
                        bundle: "com.example.tool", name: "Tool")
        let helper = proc(52, path: "/Applications/Suite.app/Contents/Applications/Tool.app/Contents/XPCServices/H.xpc/Contents/MacOS/H")
        let p = plan([editor(), tool, helper], front: 10)
        XCTAssertEqual(pids(p.frozen, "com.example.tool"), [51, 52])
    }

    func testASystemToolAndAUsersToolOfTheSameNameAreNotMixed() {
        for order in [[140, 141], [141, 140]] as [[pid_t]] {
            let paths: [pid_t: String] = [140: "/usr/bin/runner", 141: "/opt/tools/bin/runner"]
            let list = [editor()] + order.map { proc($0, parent: 1, path: paths[$0]!) }
            let p = plan(list, front: 10)
            XCTAssertEqual(pids(p.frozen, "exe:runner"), [141], "order \(order)")
        }
    }

    func testAKeptNameCannotBeBorrowedFromASystemTool() {
        // The front pid is a system tool called runner; a user's runner elsewhere is not "in front".
        let list = [editor(), proc(140, path: "/usr/bin/runner"), proc(141, path: "/opt/tools/bin/runner")]
        let p = plan(list, front: 140)
        XCTAssertTrue(p.kept.isEmpty)
        XCTAssertEqual(pids(p.frozen, "exe:runner"), [141])
    }

    func testTwoCopiesOfAnAppAreOneGroupNamedByTheLowestPid() {
        let first = proc(70, path: "/Applications/Memo.app/Contents/MacOS/Memo", app: .regular, bundle: "com.example.memo", name: "Memo")
        let second = proc(60, path: "/Users/me/Applications/Memo.app/Contents/MacOS/Memo", app: .regular,
                          bundle: "com.example.memo", name: "Memo Copy")
        for list in [[editor(), first, second], [second, first, editor()]] {
            let p = plan(list, front: 10)
            XCTAssertEqual(ids(p.frozen), ["com.example.memo"])
            XCTAssertEqual(pids(p.frozen, "com.example.memo"), [60, 70])
            XCTAssertEqual(p.frozen.first?.name, "Memo Copy")
        }
    }

    // ── Order ───────────────────────────────────────────────────────────────

    func testGroupsAreOrderedByNameThenIdAndMembersByPid() {
        func named(_ pid: pid_t, _ id: String, _ name: String) -> UltraProcess {
            proc(pid, path: "/Applications/\(id).app/Contents/MacOS/\(name)", app: .regular, bundle: id, name: name)
        }
        let list = [named(300, "Zeta", "Zeta"), named(200, "SameB", "Same"), named(250, "SameA", "Same"), named(100, "Alpha", "Alpha"),
                    proc(310, parent: 300, path: "/bin/zsh"), proc(120, parent: 300, path: "/bin/zsh"), editor(10)]
        let a = plan(list, front: 10)
        XCTAssertEqual(ids(a.frozen), ["Alpha", "SameA", "SameB", "Zeta"])
        XCTAssertEqual(pids(a.frozen, "Zeta"), [120, 300, 310])
        XCTAssertEqual(a, plan(Array(list.reversed()), front: 10))
    }

    // ── What starts later ───────────────────────────────────────────────────

    func testANewProcessOfAFrozenGroupIsAnAddition() {
        let list = [editor(), browser(),
                    proc(23, parent: 20, path: "/Applications/Browser.app/Contents/Frameworks/Helper")]
        let adds = additions(list, frozen: ["com.example.browser"], known: [20])
        XCTAssertEqual(ids(adds), ["com.example.browser"])
        XCTAssertEqual(adds.first?.name, "Browser")
        XCTAssertEqual(adds.first?.members, [FreezeGroup.Member(pid: 23, startTime: 230)])
    }

    func testANewProcessOfAKeptAppIsNotAnAddition() {
        let list = [editor(), proc(13, parent: 10, path: "/bin/zsh"), browser()]
        // The editor is kept, so it is not among the frozen groups the sweep is given.
        XCTAssertEqual(additions(list, frozen: ["com.example.browser"], known: [20]), [])
    }

    func testANewAppIsNotAnAddition() {
        let list = [editor(), browser(), app(60, "com.example.late", "Late")]
        XCTAssertEqual(additions(list, frozen: ["com.example.browser"], known: [10, 20]), [])
    }

    func testKnownPidsAreNotAdditions() {
        let list = [browser(), proc(21, parent: 20, path: "/bin/zsh"), proc(22, parent: 20, path: "/bin/zsh")]
        let adds = additions(list, frozen: ["com.example.browser"], known: [20, 21])
        XCTAssertEqual(adds.flatMap(\.members).map(\.pid), [22])
        XCTAssertEqual(additions(list, frozen: ["com.example.browser"], known: [20, 21, 22]), [])
    }

    func testAReleasedGroupGainsNothing() {
        // The sweep is given only the groups still frozen; a released one is not among them.
        let list = [browser(), proc(23, parent: 20, path: "/bin/zsh")]
        XCTAssertEqual(additions(list, frozen: [], known: [20]), [])
    }

    func testANewRootProcessInsideAFrozenAppIsNotAnAddition() {
        let list = [browser(), proc(23, uid: 0, path: "/Applications/Browser.app/Contents/Library/LaunchServices/root")]
        XCTAssertEqual(additions(list, frozen: ["com.example.browser"], known: [20]), [])
    }

    func testANewSystemToolOfTheNameOfAFrozenToolIsNotAnAddition() {
        let list = [proc(140, path: "/opt/tools/bin/runner"), proc(141, path: "/usr/bin/runner")]
        XCTAssertEqual(additions(list, frozen: ["exe:runner"], known: [140]), [])
    }

    func testANewToolWithNoReadablePathAndNoAppIsNotAnAddition() {
        let list = [proc(140, path: "/opt/tools/bin/runner"), proc(141, path: "", name: "runner")]
        XCTAssertEqual(additions(list, frozen: ["exe:runner"], known: [140]), [])
    }

    func testANewProcessWithNoReadablePathTiedToAFrozenAppIsAnAddition() {
        let list = [browser(), proc(23, parent: 20, path: "")]
        XCTAssertEqual(additions(list, frozen: ["com.example.browser"], known: [20]).flatMap(\.members).map(\.pid), [23])
    }

    func testANewExtensionOfAFrozenAppIsNotAnAddition() {
        let list = [browser(), proc(23, parent: 20, path: "/Applications/Browser.app/Contents/PlugIns/Some.appex/Contents/MacOS/Some")]
        XCTAssertEqual(additions(list, frozen: ["com.example.browser"], known: [20]), [])
    }

    func testANewEventTapOwnerOrMicrophoneUserIsNotAnAddition() {
        let tap = proc(23, parent: 20, path: "/bin/zsh", tap: true)
        let mic = proc(24, parent: 20, path: "/bin/zsh", mic: true)
        let plain = proc(25, parent: 20, path: "/bin/zsh")
        let adds = additions([browser(), tap, mic, plain], frozen: ["com.example.browser"], known: [20])
        XCTAssertEqual(adds.flatMap(\.members).map(\.pid), [25])
    }

    func testAnodesOwnNewProcessIsNotAnAddition() {
        let list = [browser(), proc(23, parent: 20, path: "/bin/zsh")]
        XCTAssertEqual(additions(list, frozen: ["com.example.browser"], known: [20], ownPIDs: [23]), [])
    }

    func testAdditionsAreOrderedLikeThePlan() {
        let list = [app(300, "com.example.zeta", "Zeta"), app(100, "com.example.alpha", "Alpha"),
                    proc(320, parent: 300, path: "/bin/zsh"), proc(310, parent: 300, path: "/bin/zsh"),
                    proc(110, parent: 100, path: "/bin/zsh")]
        let adds = additions(list, frozen: ["com.example.zeta", "com.example.alpha"], known: [100, 300])
        XCTAssertEqual(ids(adds), ["com.example.alpha", "com.example.zeta"])
        XCTAssertEqual(adds.last?.members.map(\.pid), [310, 320])
    }
}
