// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "audioctl",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "audioctl",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("Carbon"),
                .linkedFramework("AppKit"),
            ]
        )
    ]
)
