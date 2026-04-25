// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MetaWhisp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MetaWhisp", targets: ["MetaWhisp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "MetaWhisp",
            dependencies: [
                "WhisperKit",
                "Sparkle",
            ],
            path: ".",
            exclude: ["Package.swift", "Resources", "mockup-liquid-glass"],
            resources: [
                .copy("Resources/Sounds"),
                .process("Resources/mw_menubar.png"),
                .process("Resources/mw_menubar@2x.png"),
                .process("Resources/AppIcon.png"),
            ]
        ),
    ]
)
