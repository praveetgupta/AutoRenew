// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AutoRenew",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "AutoRenew", targets: ["AutoRenewApp"]),
        // Named autorenew-cli (not "autorenew") because macOS filesystems are case-insensitive
        // and it would collide with the AutoRenew app binary in .build/.
        .executable(name: "autorenew-cli", targets: ["AutoRenewCLI"]),
        .library(name: "AutoRenewCore", targets: ["AutoRenewCore"]),
    ],
    targets: [
        .target(name: "AutoRenewCore"),
        .executableTarget(name: "AutoRenewApp", dependencies: ["AutoRenewCore"]),
        .executableTarget(name: "AutoRenewCLI", dependencies: ["AutoRenewCore"]),
        .testTarget(name: "AutoRenewCoreTests", dependencies: ["AutoRenewCore"]),
    ]
)
