import Foundation

/// What this build is, read out of the bundle's Info.plist.
///
/// Settings, the About box and Developer Tools → Anode Stats all say which build
/// is running, and each reading the plist for itself is how three screens come to
/// disagree about it. Takes the dictionary rather than reading `Bundle.main` so it
/// can be tested, and so a `swift run` binary — which has no Info.plist at all —
/// is a case the type handles instead of one it crashes on.
public struct BuildInfo: Equatable {
    public let version: String
    public let build: String
    /// The short hash `build-app.sh` recorded, without the dirty marker. nil when
    /// it is absent or "unknown" — the value the script writes when git could not
    /// be read, and one that says less than not raising the subject.
    public let commit: String?
    /// `build-app.sh` appends "+" when the tree differed from HEAD, so the hash
    /// alone does not identify the build.
    public let isModified: Bool
    public let sourcePath: String?

    public init(info: [String: Any]?) {
        version = info?["CFBundleShortVersionString"] as? String ?? "?"
        build = info?["CFBundleVersion"] as? String ?? "?"
        let raw = (info?["BSSourceCommit"] as? String) ?? ""
        isModified = raw.hasSuffix("+")
        let hash = isModified ? String(raw.dropLast()) : raw
        commit = hash.isEmpty || hash == "unknown" ? nil : hash
        let path = info?["BSSourcePath"] as? String
        sourcePath = (path?.isEmpty ?? true) ? nil : path
    }

    /// "1.0 (build 12) · abc1234+" — the line Settings has always shown.
    public var summary: String {
        "\(version) (build \(build)) · \(commit.map { $0 + (isModified ? "+" : "") } ?? "unknown")"
    }
}
