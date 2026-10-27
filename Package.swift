// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenWorld",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OpenWorld",
            path: "Sources/OpenWorld",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
