// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeTaskMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeTaskMonitor",
            path: "Sources/ClaudeTaskMonitor"
        )
    ]
)
