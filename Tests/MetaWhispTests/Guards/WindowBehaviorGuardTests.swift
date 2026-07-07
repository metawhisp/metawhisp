import XCTest

/// ITER-050 B2.1 — build-time guard against the recurring Space-throw bug
/// class. The bug came back repeatedly because every fix was local: a window
/// controller would re-introduce a literal `collectionBehavior` array or an
/// aggressive `NSApp.activate(ignoringOtherApps: true)` and nothing caught it.
/// These tests scan the SOURCE TREE, so any regression fails `swift test`
/// before it ever reaches a build the user runs.
final class WindowBehaviorGuardTests: XCTestCase {

    private var repoRoot: URL {
        // …/Tests/MetaWhispTests/Guards/WindowBehaviorGuardTests.swift → repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func swiftSources(under folders: [String]) -> [(path: String, source: String)] {
        var out: [(String, String)] = []
        let fm = FileManager.default
        for folder in folders {
            let base = repoRoot.appendingPathComponent(folder)
            guard let en = fm.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in en where url.pathExtension == "swift" {
                if let src = try? String(contentsOf: url, encoding: .utf8) {
                    out.append((url.path, src))
                }
            }
        }
        XCTAssertFalse(out.isEmpty, "guard must actually scan sources — path resolution broke")
        return out
    }

    /// Strip line comments so doc text mentioning banned symbols doesn't trip
    /// the guard — only CODE counts.
    private func codeLines(of src: String) -> [(n: Int, line: String)] {
        src.components(separatedBy: "\n").enumerated().map { n, raw in
            let code = raw.range(of: "//").map { String(raw[..<$0.lowerBound]) } ?? raw
            return (n + 1, code)
        }
    }

    /// LITERAL `collectionBehavior = [...]` arrays are banned — they are how
    /// the Space-throw bug re-entered the codebase every time. Assignments
    /// must reference `MWWindowBehavior.*` (directly or via a constant like
    /// `Self.windowBehavior`, which the moveToActiveSpace test keeps honest).
    func testNoLiteralCollectionBehaviorArrays() {
        for (path, src) in swiftSources(under: ["Views", "App"]) {
            for (n, line) in codeLines(of: src) {
                let isLiteral = line.range(
                    of: #"collectionBehavior\s*=\s*\["#, options: .regularExpression) != nil
                XCTAssertFalse(isLiteral,
                               "literal collectionBehavior array in \(path):\(n) — use MWWindowBehavior.*: \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
    }

    /// `.moveToActiveSpace` is banned in code — it is the Space-switching
    /// mechanic that threw the user to another Space on macOS 26.
    func testMoveToActiveSpaceIsBanned() {
        for (path, src) in swiftSources(under: ["Views", "App", "Helpers"]) {
            for (n, line) in codeLines(of: src) {
                XCTAssertFalse(line.contains(".moveToActiveSpace"),
                               "\(path):\(n) uses .moveToActiveSpace — superseded by MWWindowBehavior (ITER-050 B2.1)")
            }
        }
    }

    // NOTE: aggressive `activate(ignoringOtherApps: true)` is guarded by the
    // pre-existing `WindowActivationGuardTests` — not duplicated here.

    /// Every constant in the source of truth must carry `.fullScreenAuxiliary`.
    func testSourceOfTruthCarriesFullScreenAuxiliary() {
        let url = repoRoot.appendingPathComponent("Helpers/WindowBehavior.swift")
        guard let src = try? String(contentsOf: url, encoding: .utf8) else {
            return XCTFail("Helpers/WindowBehavior.swift missing")
        }
        let constants = src.components(separatedBy: "\n").filter { $0.contains("static let") }
        XCTAssertEqual(constants.count, 4, "unexpected constant count in MWWindowBehavior")
        for line in constants {
            XCTAssertTrue(line.contains(".fullScreenAuxiliary"),
                          "MWWindowBehavior constant without .fullScreenAuxiliary: \(line)")
        }
    }
}
