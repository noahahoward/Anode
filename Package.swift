// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BetterStats",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "PowerKit"),
        .executableTarget(name: "betterstats", dependencies: ["PowerKit"]),
        .executableTarget(name: "BetterStatsApp", dependencies: ["PowerKit"]),
        .executableTarget(name: "BetterStatsHelper", dependencies: ["PowerKit"]),
    ]
)
