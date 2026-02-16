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
    dependencies: [
        .package(url: "https://github.com/getsentry/sentry-cocoa.git", from: "8.43.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "ClawBarApp",
            dependencies: [
                .product(name: "Sentry", package: "sentry-cocoa"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/ClawBarApp",
            exclude: ["Info.plist", "ClawBar.entitlements", "Resources"]
        )
    ]
)
