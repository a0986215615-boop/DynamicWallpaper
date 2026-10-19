// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DynamicWallpaper",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "DynamicWallpaper",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("QuartzCore"),
            ]
        )
    ]
)
