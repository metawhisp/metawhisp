// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MetaWhisp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MetaWhisp", targets: ["MetaWhisp"]),
        // FEAT-0006 — the agents' way in: `metawhisp-cli mcp start` is the MCP server Claude Code / Codex launch
        // over stdio; `metawhisp-cli task …` is the command line. Both talk to the running app (the only writer).
        .executable(name: "metawhisp-cli", targets: ["MetaWhispCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0"),
        // ITER-039 — local LLM. Bare `mlx-swift` (tensor framework only,
        // no transformers dep) gives us MLX, MLXNN, MLXRandom without
        // conflicting with WhisperKit. swift-transformers is already in
        // our graph at 1.1.9 (via WhisperKit) — adding it as an explicit
        // dep at the same range lets us use Hub (HF downloads) + Tokenizers
        // (BPE) without a second resolution.
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.21.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.1.6"),
    ],
    targets: [
        .executableTarget(
            name: "MetaWhisp",
            dependencies: [
                "ObjCExceptionCatcher",
                "MetaWhispTrackerKit",
                "WhisperKit",
                "Sparkle",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXFast", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: ".",
            // `Tests/` excluded so a normal `swift build` does not pull unit
            // tests into the main app target. They live in `MetaWhispTests`.
            // `Sources/` holds the other targets (the CLI's `main.swift` would
            // clash with the SwiftUI @main) — excluded from the app target.
            exclude: ["Package.swift", "Resources", "mockup-liquid-glass", "Tests", "Sources"],
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
        // 2026-10-14 — the one place Swift can catch an Objective-C exception. AVFAudio raises one for a device it can
        // no longer use; escaped from a main-actor job it stopped the main queue and crashed the app at the next wake.
        .target(
            name: "ObjCExceptionCatcher",
            path: "Sources/ObjCExceptionCatcher"
        ),
        // FEAT-0006 — the task tracker's shared rules, value types, wire protocol and texts. Foundation only: the app
        // and the command-line tool (`metawhisp-cli`) both link it, so the two can never disagree on a rule.
        .target(
            name: "MetaWhispTrackerKit",
            path: "Sources/MetaWhispTrackerKit"
        ),
        // TDD test target (spec://specs/TDD.md). `swift test` runs this.
        // Uses `@testable import MetaWhisp` to reach internal symbols.
        .testTarget(
            name: "MetaWhispTests",
            dependencies: ["MetaWhisp", "MetaWhispTrackerKit"],
            path: "Tests/MetaWhispTests"
        ),
        // FEAT-0006 — `metawhisp-cli`: Foundation + the tracker kit only, so an agent can spawn it instantly. It never
        // opens the store; it sends each request to the app over the local socket and starts the app if needed.
        .executableTarget(
            name: "MetaWhispCLI",
            dependencies: ["MetaWhispTrackerKit"],
            path: "Sources/MetaWhispCLI"
        ),
    ]
)
