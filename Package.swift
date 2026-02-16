// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClawBarApp",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ClawBarApp", targets: ["ClawBarApp"])
    ],
    targets: [
        .executableTarget(
            name: "ClawBarApp",
            path: "Sources/ClawBarApp",
            exclude: ["Info.plist", "ClawBar.entitlements", "Resources"]
        )
    ]
)
