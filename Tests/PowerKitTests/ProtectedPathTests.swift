import XCTest
@testable import PowerKit

/// Not asking the disk about files macOS gates.
///
/// The bug this came from: Anode read other processes' executables for a
/// signing badge and a display name, and when one of those lived in Downloads
/// macOS raised a consent prompt. Unanswered — which is the normal outcome for a
/// menu bar app with no window on screen to attach it to — the app could not
/// show a window at all until it was relaunched.
final class ProtectedPathTests: XCTestCase {

    private var home: String { NSHomeDirectory() }

    func testTheGatedFoldersAreGated() {
        for folder in ["Downloads", "Desktop", "Documents", "Library/Mobile Documents"] {
            XCTAssertTrue(ProtectedPath.isGated("\(home)/\(folder)/tool"),
                          "\(folder) should be gated")
        }
    }

    func testOrdinaryInstallLocationsAreNot() {
        for path in ["/Applications/Safari.app/Contents/MacOS/Safari",
                     "/usr/bin/ssh",
                     "/System/Library/CoreServices/Finder.app",
                     "\(NSHomeDirectory())/Applications/Anode.app/Contents/MacOS/AnodeApp"] {
            XCTAssertFalse(ProtectedPath.isGated(path), path)
        }
    }

    /// A sibling whose name merely STARTS with a gated one is not inside it.
    /// Prefix matching without the separator would gate `Downloads-old`.
    func testASiblingFolderIsNotInsideTheGatedOne() {
        XCTAssertFalse(ProtectedPath.isGated("\(home)/Downloads-old/tool"))
        XCTAssertFalse(ProtectedPath.isGated("\(home)/DocumentsArchive/tool"))
    }

    /// The directory itself, with no trailing slash, is not a file we would read.
    func testTheBareFolderPathIsNotTreatedAsAFileInside() {
        XCTAssertFalse(ProtectedPath.isGated("\(home)/Downloads"))
    }

    /// `.unknown` means "we did not look", which is what every other failure in
    /// this function already returns — so no caller needs a new case.
    func testSigningOriginIsUnknownForAGatedPathRatherThanPrompting() {
        XCTAssertEqual(CodeSignature.origin(ofExecutableAt: "\(home)/Downloads/probe"),
                       .unknown)
    }
}

extension ProtectedPathTests {

    /// The other read on the same code path. `pathFacts` asks for BOTH the
    /// signing origin and the bundle's Info.plist, so guarding only the first
    /// left the prompt firing from the second.
    func testBundleFactsAreEmptyForAGatedBundleRatherThanPrompting() {
        let facts = BundleFacts.read(bundlePath: "\(NSHomeDirectory())/Downloads/Thing.app")
        XCTAssertEqual(facts.identifier, nil)
        XCTAssertEqual(facts.displayName, nil)
    }
}
