// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MetaWhisp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MetaWhisp", targets: ["MetaWhisp"]),
        // ITER-037 — standalone MCP server CLI. Claude Desktop / Cursor /
        // any MCP client launches this as a child process via stdio.
        .executable(name: "metawhisp-mcp", targets: ["MetaWhispMCP"]),
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
            // `Sources/MetaWhispMCP/` is a separate `.executableTarget` —
            // exclude it so the main MetaWhisp target doesn't ingest its
            // `main.swift` (which would clash with the SwiftUI @main).
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
        // TDD test target (spec://specs/TDD.md). `swift test` runs this.
        // Uses `@testable import MetaWhisp` to reach internal symbols.
        .testTarget(
            name: "MetaWhispTests",
            dependencies: ["MetaWhisp"],
            path: "Tests/MetaWhispTests"
        ),
        // ITER-037 — MCP server. Standalone CLI binary. Reads the
        // `mcp-snapshot.json` that the main MetaWhisp app dumps every
        // 5 min, serves it over JSON-RPC stdio to Claude Desktop / Cursor.
        // No SwiftData / no Foundation dependencies beyond stdlib —
        // intentionally lightweight so Claude can spawn it instantly.
        .executableTarget(
            name: "MetaWhispMCP",
            path: "Sources/MetaWhispMCP"
        ),
    ]
)
