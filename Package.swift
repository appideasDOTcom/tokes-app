// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tokes",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Tokes",
            path: "Sources/Tokes",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
