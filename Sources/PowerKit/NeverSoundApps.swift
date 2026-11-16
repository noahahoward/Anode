/// Apps that have no way to make sound, so a volume slider for them would only be clutter. macOS keeps no list of which apps can
/// play sound (an app that has not yet is not connected to the sound system), so this short list is by name and every other open
/// app is shown.
public enum NeverSoundApps {
    public static let bundleIDs: Set<String> = [
        "com.apple.finder", "com.apple.Terminal", "com.apple.ActivityMonitor", "com.apple.Console",
        "com.apple.systempreferences", "com.apple.keychainaccess", "com.apple.DiskUtility", "com.apple.Passwords",
        "com.apple.archiveutility", "com.apple.BluetoothFileExchange", "com.apple.ScriptEditor2", "com.apple.dt.Xcode",
    ]

    public static func contains(_ bundleID: String) -> Bool { bundleIDs.contains(bundleID) }
}
