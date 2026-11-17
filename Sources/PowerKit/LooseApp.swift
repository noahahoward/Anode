/// An app that is a bare executable, not an `.app` bundle (a game started from Steam, say), has no bundle identifier. Its path
/// stands in for one, so it can be listed, remembered and held like any other app.
public enum LooseApp {
    static let prefix = "path:"

    public static func id(forExecutable path: String) -> String { prefix + path }

    /// The executable's path when `id` was made by `id(forExecutable:)`, else nil (a real bundle id).
    public static func executablePath(from id: String) -> String? { id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : nil }
}
