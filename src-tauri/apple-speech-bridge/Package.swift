// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppleSpeechBridge",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "AppleSpeechBridge", type: .dynamic, targets: ["AppleSpeechBridge"])
    ],
    targets: [
        .target(
            name: "AppleSpeechBridge",
            path: "Sources/AppleSpeechBridge",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
