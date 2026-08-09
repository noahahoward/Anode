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
        // BetterStatsApp is here so the rail/menu ordering can be tested against
        // the real SidebarView rather than a copy of it — a duplicated list is
        // exactly the desync the tests exist to catch.
        .testTarget(name: "PowerKitTests", dependencies: ["PowerKit", "BetterStatsApp"]),
    ]
)
