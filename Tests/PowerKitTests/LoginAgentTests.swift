import XCTest
@testable import PowerKit

/// The fallback that makes "launch at login" work on an ad-hoc signed build.
///
/// SMAppService registers against a code identity. This bundle is ad-hoc signed
/// — no Team ID, cdhash changing every rebuild — so Background Task Management
/// accepted the registration and dropped it at boot: ticked the box, saw the
/// confirmation, restarted, nothing launched, status back to `.notFound`.
final class LoginAgentTests: XCTestCase {

    /// The label must not collide with the bundle id SMAppService uses for the
    /// same app, or removing one could remove the other.
    func testLabelIsDistinctFromTheBundleIdentifier() {
        XCTAssertNotEqual(LoginAgent.label, "dev.anode.app")
        XCTAssertTrue(LoginAgent.label.hasPrefix("dev.anode.app"))
    }

    func testPlistLivesInTheUserLaunchAgentsDirectory() {
        let p = LoginAgent.plistURL.path
        XCTAssertTrue(p.hasSuffix("/Library/LaunchAgents/\(LoginAgent.label).plist"), p)
        XCTAssertTrue(p.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path),
                      "a USER agent — never /Library, which would need root")
    }

    /// A stale plist pointing at a bundle that has moved must read as absent.
    /// Reporting it as installed would promise a launch that silently fails —
    /// which is the exact failure this whole fallback exists to fix.
    func testInstalledMeansPointingAtTheRunningExecutable() {
        if let recorded = LoginAgent.installedProgramPath {
            XCTAssertEqual(LoginAgent.isInstalled,
                           recorded == LoginAgent.currentExecutablePath)
        } else {
            XCTAssertFalse(LoginAgent.isInstalled,
                           "no plist means not installed, whatever else is true")
        }
    }

    /// The test binary is not an .app, so installing must refuse rather than
    /// write a plist pointing into .build/ that rots on the next clean.
    func testRefusesToInstallForAnUnbundledBuild() {
        guard !LoginAgent.isBundled else {
            return XCTAssertTrue(true, "running bundled; the guard is not exercised here")
        }
        XCTAssertThrowsError(try LoginAgent.install()) { error in
            guard case LoginAgent.Failure.notBundled = error else {
                return XCTFail("expected .notBundled, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: LoginAgent.plistURL.path),
                       "a refused install must leave nothing behind")
    }

    /// Symlink resolution, so two spellings of one path cannot read as two
    /// different programs and cause a needless reinstall on every launch.
    func testExecutablePathIsResolved() {
        let p = LoginAgent.currentExecutablePath
        XCTAssertEqual(p, URL(fileURLWithPath: p).resolvingSymlinksInPath().path)
    }
}
