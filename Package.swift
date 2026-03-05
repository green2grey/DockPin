// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DockPin",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0")
    ],
    targets: [
        .executableTarget(
            name: "DockPin",
            dependencies: ["Sparkle"],
            path: "Sources"
        )
    ]
)
