// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Tono",
    platforms: [
        .macOS(.v26)
    ],
    dependencies: [
        .package(url: "https://github.com/AudioKit/AudioKit.git", from: "5.6.2"),
        .package(url: "https://github.com/AudioKit/SoundpipeAudioKit.git", from: "5.6.2"),
    ],
    targets: [
        .executableTarget(
            name: "Tono",
            dependencies: [
                .product(name: "AudioKit", package: "AudioKit"),
                .product(name: "SoundpipeAudioKit", package: "SoundpipeAudioKit"),
            ],
            path: "Tono",
            resources: [
                .copy("Resources/MelBandRoFormer.mlmodelc")
            ]
        )
    ]
)
