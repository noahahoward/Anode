import Foundation

/// One audio client as Core Audio lists it.
public struct AudioProcessInfo: Equatable {
    public let objectID: UInt32
    public let pid: Int32
    public let executablePath: String
    public let isRunningOutput: Bool
    public init(objectID: UInt32, pid: Int32, executablePath: String, isRunningOutput: Bool) {
        self.objectID = objectID; self.pid = pid; self.executablePath = executablePath; self.isRunningOutput = isRunningOutput
    }
}

/// An app, as the person knows it: its audio processes (a browser has several) taken together.
public struct AudioApp: Equatable {
    public let bundleID: String
    public let name: String
    public let appPath: String
    public var processObjectIDs: [UInt32]
    public var isPlaying: Bool
}

public enum AudioAppGrouping {

    /// The `.app` that holds `executablePath`, the outermost one: a helper app inside a browser belongs to the browser.
    public static func outermostAppPath(_ executablePath: String) -> String? {
        let parts = executablePath.split(separator: "/", omittingEmptySubsequences: true)
        guard let i = parts.firstIndex(where: { $0.hasSuffix(".app") && $0.count > 4 }) else { return nil }
        return "/" + parts[0...i].joined(separator: "/")
    }

    /// Audio processes grouped into apps. A process that belongs to no app (a command-line tool, a system daemon), and an app with
    /// no bundle identifier that is not one of `looseApps`, are left out. Playing apps first, then by name.
    /// `looseApps` are the executable paths of open apps that are not bundles: a process running one of those is that app.
    public static func group(_ processes: [AudioProcessInfo], bundleID: (String) -> String?, name: (String) -> String,
                             looseApps: Set<String> = []) -> [AudioApp] {
        var byPath: [String: AudioApp] = [:]
        for p in processes {
            guard let path = outermostAppPath(p.executablePath) ?? (looseApps.contains(p.executablePath) ? p.executablePath : nil) else { continue }
            if var app = byPath[path] {
                app.processObjectIDs.append(p.objectID)
                app.isPlaying = app.isPlaying || p.isRunningOutput
                byPath[path] = app
            } else if let id = looseApps.contains(path) ? LooseApp.id(forExecutable: path) : bundleID(path), !id.isEmpty {
                byPath[path] = AudioApp(bundleID: id, name: name(path), appPath: path, processObjectIDs: [p.objectID], isPlaying: p.isRunningOutput)
            }
        }
        return byPath.values.sorted {
            if $0.isPlaying != $1.isPlaying { return $0.isPlaying }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
