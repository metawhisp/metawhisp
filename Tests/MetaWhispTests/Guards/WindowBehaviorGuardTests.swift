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

    /// The main window comes to the user's Space: `MWWindowBehavior.main` carries
    /// `.moveToActiveSpace` and `.fullScreenAuxiliary`, and is never sticky.
    /// 2026-10-19: the transient join-all-Spaces + park design dropped
    /// `.moveToActiveSpace`, and 9 of 10 re-opens on the owner's Mac landed on
    /// the Space the window was parked on — the user dragged with it.
    func testTheMainWindowComesToTheUsersSpace() throws {
        let url = repoRoot.appendingPathComponent("Helpers/WindowBehavior.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        let main = try XCTUnwrap(codeLines(of: src).first { $0.line.contains("static let main") }?.line)
        XCTAssertTrue(main.contains(".moveToActiveSpace"), "the main window must move to the user's Space when shown: \(main)")
        XCTAssertTrue(main.contains(".fullScreenAuxiliary"), main)
        XCTAssertFalse(main.contains(".canJoinAllSpaces"), "a sticky main window is its own regression: \(main)")
        for (path, src) in swiftSources(under: ["Views", "App", "Helpers"]) {
            for (n, line) in codeLines(of: src) {
                XCTAssertFalse(line.contains("mainParked"), "\(path):\(n) parks a window — the park is what threw the user")
            }
        }
    }

    /// The main window's behavior is set once, when it is created, and never
    /// changed afterwards: the transient re-set around the order-in was the
    /// 2026-07-07 wrong turn.
    func testTheMainWindowsBehaviorIsSetOnceAtCreation() throws {
        let url = repoRoot.appendingPathComponent("Views/Windows/MainWindowController.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        let assignments = codeLines(of: src).filter { $0.line.contains("collectionBehavior =") }
        XCTAssertEqual(assignments.map(\.n).count, 1, "the main window's behavior is assigned once: \(assignments.map(\.n))")
    }

    /// No window of the app is kept hidden (2026-10-19): the main window closes
    /// for real — the delegate never turns a close into a hide — and the closed
    /// window is released. The only order-outs are the two inside `show`, each
    /// right before an order-front.
    func testTheMainWindowIsNeverKeptHidden() throws {
        let url = repoRoot.appendingPathComponent("Views/Windows/MainWindowController.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        let code = codeLines(of: src)
        XCTAssertFalse(code.contains { $0.line.contains("windowShouldClose") }, "a close is never intercepted into a hide")
        XCTAssertTrue(code.contains { $0.line.contains("func windowWillClose(") }, "the closed window is released")
        let orderOuts = code.filter { $0.line.contains("orderOut(") }.map(\.n)
        XCTAssertEqual(orderOuts.count, 2, "order-outs only inside show, before an order-front: lines \(orderOuts)")
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
        XCTAssertEqual(constants.count, 3, "unexpected constant count in MWWindowBehavior")
        for line in constants {
            XCTAssertTrue(line.contains(".fullScreenAuxiliary"),
                          "MWWindowBehavior constant without .fullScreenAuxiliary: \(line)")
        }
    }
}
