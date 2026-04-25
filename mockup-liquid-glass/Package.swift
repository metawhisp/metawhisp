// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LiquidGlassMockup",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LiquidGlassMockup", targets: ["LiquidGlassMockup"]),
    ],
    targets: [
        .executableTarget(
            name: "LiquidGlassMockup",
            path: "Sources/LiquidGlassMockup"
        ),
    ]
)
