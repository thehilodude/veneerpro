// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VeneerPro",
    platforms: [.macOS("27.0")],
    targets: [
        .executableTarget(
            name: "VeneerPro",
            path: "Sources/VeneerPro",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
