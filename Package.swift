// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SuperAV",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(name: "SuperAV", targets: ["SuperAV"]),
    ],
    targets: [
        .executableTarget(
            name: "SuperAV",
            path: ".",
            exclude: [
                "README.md",
                "SuperAV.app",
                "build-app.sh",
                "icon-film-audio.png",
                "speakers-3-colorful.png",
            ],
            sources: [
                "AudioBalance.swift",
                "SoundSourceWorkflow.swift",
                "DisplayBrightness.swift",
                "SuperAVApp.swift",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Cocoa"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
    ]
)
