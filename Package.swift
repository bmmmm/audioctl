// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "audioctl",
    platforms: [.macOS(.v12)],
    targets: [
        .target(
            name: "AudioCtlCore",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("Carbon"),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(name: "audioctl", dependencies: ["AudioCtlCore"]),
        .testTarget(name: "AudioCtlCoreTests", dependencies: ["AudioCtlCore"]),
    ]
)
