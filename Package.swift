// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tokes",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Test-only: SwiftUI runtime inspection, so tests can tap buttons and
        // fire onChange without a window. Nothing in Sources/ may import it.
        .package(url: "https://github.com/nalexn/ViewInspector", from: "0.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "Tokes",
            path: "Sources/Tokes",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TokesTests",
            dependencies: ["Tokes", "ViewInspector"],
            path: "Tests/TokesTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
