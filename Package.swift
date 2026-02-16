// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceBridgeApp",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "VoiceBridgeApp", targets: ["VoiceBridgeApp"])
    ],
    targets: [
        .executableTarget(
            name: "VoiceBridgeApp",
            path: "Sources/VoiceBridgeApp",
            exclude: ["Info.plist", "VoiceBridge.entitlements", "Resources"]
        )
    ]
)
