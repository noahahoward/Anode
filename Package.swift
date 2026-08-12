// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Anode",
    platforms: [.macOS(.v13)],
    targets: [
        // Three lines of C so Swift can see `launch_activate_socket`, which is
        // public SDK API that Darwin's module map happens not to export. See the
        // header for why it is a wrapper rather than a re-export.
        .target(name: "CLaunchActivate"),
        .target(name: "PowerKit", dependencies: ["CLaunchActivate"]),
        .executableTarget(name: "anode", dependencies: ["PowerKit"]),
        .executableTarget(name: "AnodeApp", dependencies: ["PowerKit"]),
        .executableTarget(name: "AnodeHelper", dependencies: ["PowerKit"]),
        // AnodeApp is here so the rail/menu ordering can be tested against
        // the real SidebarView rather than a copy of it — a duplicated list is
        // exactly the desync the tests exist to catch.
        .testTarget(name: "PowerKitTests", dependencies: ["PowerKit", "AnodeApp"]),
    ]
)
