// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Unduck",
    platforms: [.macOS("14.4")],
    targets: [
        .executableTarget(
            name: "Unduck",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
