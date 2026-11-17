import Foundation

/// Which apps the Battery menu lists under "Using Significant Energy", from Anode's own measurements.
///
/// macOS lists an app once it has used about 0.3 to 0.55 W for a minute or two (measured with a test app: listed at a steady 0.55 W or
/// more, never at 0.25 W or less; spread over several threads the same CPU time, which draws far less power, was never listed, so it
/// is the power that counts). On this battery that is about 0.4 to 0.73 %/hr. Anode's minimum is the middle of that, and a row already
/// there stays until the app falls well below it, so rows do not come and go while an app hovers at the line.
public enum SignificantEnergy {

    /// What an app must use, in percent of a full battery per hour, to be listed.
    public static let minimumPercentPerHour = 0.5
    /// What a row already listed keeps while the app stays at or above.
    public static let keepAtPercentPerHour = 0.35
    /// The most rows the menu shows.
    public static let maxApps = 6

    /// One thing Anode has measured: an application when it has a bundle (`isApp`), else a daemon or a tool.
    public struct Candidate: Equatable {
        public var name: String
        public var isApp: Bool
        public var stats: EnergyStats
        public init(name: String, isApp: Bool, stats: EnergyStats) { self.name = name; self.isApp = isApp; self.stats = stats }
    }

    /// The rows for the menu, the biggest drain first. `alreadyListed` are the names on the open menu now.
    public static func apps(from candidates: [Candidate], alreadyListed: Set<String>) -> [BatteryMenuModel.EnergyApp] {
        candidates
            .filter { $0.isApp }
            .filter { c in
                c.stats.pctPerHour >= minimumPercentPerHour
                    || (alreadyListed.contains(c.name) && c.stats.pctPerHour >= keepAtPercentPerHour)
            }
            .sorted { $0.stats.pctPerHour != $1.stats.pctPerHour ? $0.stats.pctPerHour > $1.stats.pctPerHour : $0.name < $1.name }
            .prefix(maxApps)
            .map { BatteryMenuModel.EnergyApp(name: $0.name, stats: $0.stats) }
    }
}
