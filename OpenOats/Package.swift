// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "OpenOats",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(
            name: "OpenOatsKit",
            targets: ["OpenOatsKit"]
        ),
        .executable(
            name: "OpenOats",
            targets: ["OpenOatsAppExecutable"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/clerk/clerk-ios.git", from: "1.0.0"),
        .package(url: "https://github.com/clerk/clerk-convex-swift", from: "0.1.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.9"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
        .package(url: "https://github.com/sindresorhus/LaunchAtLogin-Modern", from: "1.1.0"),
    ],
    targets: [
        .target(
            name: "OpenOatsKit",
            dependencies: [
                .product(name: "ClerkConvex", package: "clerk-convex-swift"),
                .product(name: "ClerkKit", package: "clerk-ios"),
                .product(name: "ClerkKitUI", package: "clerk-ios"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "LaunchAtLogin", package: "LaunchAtLogin-Modern"),
            ],
            path: "Sources/OpenOats",
            exclude: ["Info.plist", "OpenOats.entitlements", "Assets", "Resources"]
        ),
        .executableTarget(
            name: "OpenOatsAppExecutable",
            dependencies: ["OpenOatsKit"],
            path: "Sources/OpenOatsApp"
        ),
        .testTarget(
            name: "OpenOatsTests",
            dependencies: ["OpenOatsKit"],
            path: "Tests/OpenOatsTests"
        ),
    ]
)
