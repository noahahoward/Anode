import XCTest
@testable import PowerKit

/// The rollup exists so nine "Brave Browser Helper" rows become one Brave row.
/// The failure mode being pinned: helper .app bundles NESTED inside the real app
/// (Chromium/Electron layout) must resolve to the OUTERMOST bundle. None of these
/// paths need to exist on disk — resolution is path arithmetic, so the tests are
/// deterministic on any machine.
final class AppIdentityTests: XCTestCase {

    // Outermost-.app rule, on the exact real-world path that motivated it.
    func testOutermostAppWinsForNestedHelperBundle() {
        let helper = "/Applications/Brave Browser.app/Contents/Frameworks/X.framework/Helpers/Brave Browser Helper.app/Contents/MacOS/Brave Browser Helper"
        let id = AppResolver.identity(forExecutablePath: helper)

        XCTAssertEqual(id.bundlePath, "/Applications/Brave Browser.app",
                       "must take the OUTERMOST .app, not the inner helper bundle")
        XCTAssertEqual(id.name, "Brave Browser")
        XCTAssertTrue(id.isApp)
    }

    // The main binary and a nested helper must collapse to the SAME identity —
    // that equality is what makes the dictionary grouping merge them.
    func testMainBinaryAndHelperShareOneIdentity() {
        let main = AppResolver.identity(forExecutablePath:
            "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser")
        let helper = AppResolver.identity(forExecutablePath:
            "/Applications/Brave Browser.app/Contents/Frameworks/X.framework/Helpers/Brave Browser Helper.app/Contents/MacOS/Brave Browser Helper")
        XCTAssertEqual(main, helper)
    }

    // A daemon outside any bundle keeps its own name and is not an app. Pretending
    // daemons belong to apps would fabricate attribution — the ledger's cardinal sin.
    func testDaemonPathIsNotAnApp() {
        let id = AppResolver.identity(forExecutablePath: "/usr/libexec/contactsd")
        XCTAssertFalse(id.isApp)
        XCTAssertEqual(id.name, "contactsd")
        XCTAssertNil(id.bundlePath)
        XCTAssertNil(id.bundleID)
    }

    // Empty path (EPERM on proc_pidpath, or the process died): degrade to a pid
    // label, never crash, never claim app-hood.
    func testEmptyPathFallsBackToPidLabel() {
        let id = AppResolver.identity(forExecutablePath: "", fallbackPID: 4242)
        XCTAssertEqual(id.name, "pid 4242")
        XCTAssertFalse(id.isApp)
    }

    // The rollup: many processes, three owners. Joules and watts must SUM (energy is
    // additive), %/hr must be recomputed from the summed watts, and pids must be
    // complete and sorted. Uses fake bundles so no installed app can perturb it.
    func testGroupingSumsAcrossProcesses() {
        let appMain = "/Applications/PhantomBrowser.app/Contents/MacOS/PhantomBrowser"
        let appHelper = "/Applications/PhantomBrowser.app/Contents/Frameworks/PhantomKit.framework/Helpers/Phantom Helper (Renderer).app/Contents/MacOS/Phantom Helper (Renderer)"
        let drains = [
            makeDrain(pid: 100, path: appMain, joules: 1.0, watts: 0.5),
            makeDrain(pid: 300, path: appHelper, joules: 3.0, watts: 1.5),
            makeDrain(pid: 200, path: appHelper, joules: 2.0, watts: 1.0),
            makeDrain(pid: 50, path: "/usr/libexec/phantomd", joules: 4.0, watts: 2.0),
            makeDrain(pid: 400, path: "/Applications/Solitaire.app/Contents/MacOS/Solitaire",
                      joules: 0.5, watts: 0.25),
        ]

        let apps = DrainCalculator.group(drains, scale: makeExactScale())
        XCTAssertEqual(apps.count, 3)

        // Sorted by %/hr descending: browser (3 W) > daemon (2 W) > solitaire (0.25 W).
        XCTAssertEqual(apps.map(\.name), ["PhantomBrowser", "phantomd", "Solitaire"])

        let browser = apps[0]
        XCTAssertEqual(browser.identity.bundlePath, "/Applications/PhantomBrowser.app")
        XCTAssertTrue(browser.isApp)
        XCTAssertEqual(browser.processCount, 3)
        XCTAssertEqual(browser.pids, [100, 200, 300], "pids must be complete and sorted")
        XCTAssertEqual(browser.joules, 6.0, accuracy: 1e-12)
        XCTAssertEqual(browser.watts, 3.0, accuracy: 1e-12)
        // Exact scale: %/hr == watts. Recomputed from the SUM, not summed from rows,
        // so per-row rounding cannot accumulate.
        XCTAssertEqual(browser.percentPerHour, 3.0, accuracy: 1e-12)

        let daemon = apps[1]
        XCTAssertFalse(daemon.isApp)
        XCTAssertEqual(daemon.processCount, 1)
        XCTAssertEqual(daemon.joules, 4.0, accuracy: 1e-12)

        // Conservation: grouping must neither create nor destroy energy.
        XCTAssertEqual(apps.reduce(0) { $0 + $1.joules },
                       drains.reduce(0) { $0 + $1.joules }, accuracy: 1e-12)
        XCTAssertEqual(apps.reduce(0) { $0 + $1.watts },
                       drains.reduce(0) { $0 + $1.watts }, accuracy: 1e-12)
    }
}
