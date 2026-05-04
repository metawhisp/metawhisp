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
            // `Tests/` excluded so a normal `swift build` does not pull unit
            // tests into the main app target. They live in `MetaWhispTests`.
            exclude: ["Package.swift", "Resources", "mockup-liquid-glass", "Tests"],
            resources: [
                .copy("Resources/Sounds"),
                .process("Resources/mw_menubar.png"),
                .process("Resources/mw_menubar@2x.png"),
                .process("Resources/AppIcon.png"),
                // Shrek pill — HEVC + alpha .mov used by ShrekPillView
                // (5th entry in `AppSettings.pillStyle`, 2026-05-02).
                .copy("Resources/shrek-pill.mov"),
            ]
        ),
        // TDD test target (spec://specs/TDD.md). `swift test` runs this.
        // Uses `@testable import MetaWhisp` to reach internal symbols.
        .testTarget(
            name: "MetaWhispTests",
            dependencies: ["MetaWhisp"],
            path: "Tests/MetaWhispTests"
        ),
    ]
)
