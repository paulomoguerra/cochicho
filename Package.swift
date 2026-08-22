// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cochicho",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.6"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0")
    ],
    targets: [
        .executableTarget(
            name: "Cochicho",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "Sources/Cochicho",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CochichoTests",
            dependencies: ["Cochicho"],
            path: "Tests/CochichoTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
