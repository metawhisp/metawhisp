import XCTest

/// ITER-044 044.2 — build-time guard for invariant I2: NO Apple Foundation
/// Models symbol may be reachable below macOS 26. The deployment target is
/// macOS 14, so an unguarded `SystemLanguageModel` / `LanguageModelSession` /
/// `GenerationOptions` use would crash on Sonoma/Sequoia at launch. The Swift
/// compiler already enforces this, but a stray `@available` annotation could be
/// deleted in a refactor — this test scans the SOURCE TREE and fails
/// `swift test` before such a regression reaches a build the user runs.
final class FoundationModelsAvailabilityGuardTests: XCTestCase {

    private var repoRoot: URL {
        // …/Tests/MetaWhispTests/Guards/<this>.swift → repo root (4 levels up)
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// FM-only type names. Precise enough to have zero false positives (none of
    /// these appear as unrelated identifiers in this codebase). `session.respond`
    /// / `.availability` lines carry no type name, but they only ever appear
    /// INSIDE the annotated methods, so the enclosing-scope check covers them.
    private let fmSymbols = ["SystemLanguageModel", "LanguageModelSession", "GenerationOptions"]

    private func swiftSources(under folder: String) -> [(path: String, source: String)] {
        var out: [(String, String)] = []
        let fm = FileManager.default
        let base = repoRoot.appendingPathComponent(folder)
        guard let en = fm.enumerator(at: base, includingPropertiesForKeys: nil) else { return out }
        for case let url as URL in en where url.pathExtension == "swift" {
            if let src = try? String(contentsOf: url, encoding: .utf8) {
                out.append((url.path, src))
            }
        }
        return out
    }

    /// Strip `//` line comments so doc text mentioning an FM type doesn't trip
    /// the guard — only CODE counts.
    private func codeOnly(_ line: String) -> String {
        line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
    }

    func test_noFoundationModelsSymbolOutsideAvailabilityGuard() {
        let sources = swiftSources(under: "Services")
        XCTAssertFalse(sources.isEmpty, "guard must actually scan Services/ — path resolution broke")

        var sawAnyFMSymbol = false

        for (path, src) in sources {
            var depth = 0
            var guardedOpenDepths: Set<Int> = []   // brace depths whose body is availability-guarded
            var pending = false                    // saw a guard marker; applies at the next `{`

            for rawLine in src.components(separatedBy: "\n") {
                let code = codeOnly(rawLine)

                if code.contains("@available(macOS 26") || code.contains("#available(macOS 26") {
                    pending = true
                }

                if fmSymbols.contains(where: { code.contains($0) }) {
                    sawAnyFMSymbol = true
                    let isGuarded = pending || !guardedOpenDepths.isEmpty
                    XCTAssertTrue(isGuarded,
                        "Unguarded FoundationModels symbol in \(path): \(rawLine.trimmingCharacters(in: .whitespaces)) — wrap it in @available(macOS 26, *) / if #available(macOS 26, *)")
                }

                // Advance brace depth; a `{` following a guard marker opens a
                // guarded scope at that depth.
                for ch in code {
                    if ch == "{" {
                        depth += 1
                        if pending { guardedOpenDepths.insert(depth); pending = false }
                    } else if ch == "}" {
                        guardedOpenDepths.remove(depth)
                        depth = max(0, depth - 1)
                    }
                }
            }
        }

        // Sanity: the scanner actually saw the FM backend (otherwise the test
        // would pass vacuously if the file moved / symbols were renamed).
        XCTAssertTrue(sawAnyFMSymbol,
            "guard found no FoundationModels symbols at all — did LocalLLMService's FM backend move or get renamed?")
    }
}
