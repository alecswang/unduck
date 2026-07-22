// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "probe",
    platforms: [.macOS("14.4")],
    targets: [
        .executableTarget(
            name: "probe",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                // TCC reads NSAudioCaptureUsageDescription out of the binary's
                // embedded __info_plist section for a plain CLI executable.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Info.plist",
                ])
            ]
        )
    ]
)
