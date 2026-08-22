// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EkoNami",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.6"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0")
    ],
    targets: [
        .executableTarget(
            name: "EkoNami",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "Sources/EkoNami",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "EkoNamiTests",
            dependencies: ["EkoNami"],
            path: "Tests/EkoNamiTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
