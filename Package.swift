// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TheThinkingNotebook",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TheThinkingNotebook",
            path: "Sources/TheThinkingNotebook"
        )
    ],
    swiftLanguageModes: [.v5]
)
