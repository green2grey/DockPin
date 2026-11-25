// swift-tools-version: 5.9
import Foundation
import PackageDescription

// DOCKPIN_WITHOUT_SPARKLE=1 builds DockPin without Sparkle, for package managers that update the
// app themselves (Nix, a Homebrew formula built from source). Settings then says so instead of
// offering update checks.
let withSparkle = ProcessInfo.processInfo.environment["DOCKPIN_WITHOUT_SPARKLE"] == nil

let package = Package(
    name: "DockPin",
    platforms: [.macOS(.v13)],
    dependencies: withSparkle
        ? [.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0")]
        : [],
    targets: [
        .executableTarget(
            name: "DockPin",
            dependencies: withSparkle ? ["Sparkle"] : [],
            path: "Sources"
        ),
        .testTarget(
            name: "DockPinTests",
            dependencies: ["DockPin"],
            path: "Tests"
        )
    ]
)
