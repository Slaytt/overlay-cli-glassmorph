// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VibeTerminal",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "VibeTerminal",
            path: "Sources/VibeTerminal"
        )
    ]
)
