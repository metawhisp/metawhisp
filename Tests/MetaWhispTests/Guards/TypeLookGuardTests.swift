import XCTest
@testable import MetaWhisp

/// ITER-087 — one type system in the window: caps only for micro-labels (section headers and captions, drawn by
/// `mwBadge`/`blocksLabel` in SF Mono caps) and the PRO mark; buttons, tabs, chips and row names in sentence case.
/// Before the new look ~100 caps literals and ~45 `.uppercased()` calls set their own tracked caps. This scans the
/// SOURCE of the window, the popover and the shared primitives so a caps button or tab does not come back. A caps
/// literal is allowed when `mwBadge`/`blocksLabel` styles it within the next lines. Onboarding and the post-update
/// intro keep their own look (owner, 2026-11-25).
final class TypeLookGuardTests: XCTestCase {
    private var repoRoot: URL {
        // …/Tests/MetaWhispTests/Guards/TypeLookGuardTests.swift → repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func scannedFiles() throws -> [URL] {
        var files: [URL] = []
        for folder in ["Views/Windows", "Views/MenuBar"] {
            let root = repoRoot.appendingPathComponent(folder)
            let walker = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            files += walker.compactMap { $0 as? URL }.filter {
                $0.pathExtension == "swift"
                    && !$0.path.contains("/Views/Windows/Onboarding/")
                    && !$0.path.contains("/Views/Windows/TargetIntro/")
            }
        }
        for file in ["Views/Components/GlassPrimitives.swift", "Views/Components/StatComponents.swift",
                     "Views/Components/AppPickerView.swift", "Helpers/DesignSystem.swift"] {
            files.append(repoRoot.appendingPathComponent(file))
        }
        return files
    }

    /// The letters a string literal shows: interpolations and escapes removed.
    private func shownLetters(_ literal: String) -> String {
        var text = literal
        for pattern in [#"\\\([^)]*\)"#, #"\\u\{[0-9A-Fa-f]+\}"#, #"\\."#] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return String(text.filter(\.isLetter))
    }

    func testNoButtonOrTabIsSetInItsOwnCaps() throws {
        let files = try scannedFiles()
        XCTAssertGreaterThan(files.count, 25, "the guard must read the views — path resolution broke")
        let literal = try NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
        var offenders: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let code = line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
                guard code.contains("Text(") || code.contains("Button(") || code.contains("label: \"") else { continue }
                let range = NSRange(code.startIndex..., in: code)
                let caps = literal.matches(in: code, range: range).compactMap { match -> String? in
                    guard let inner = Range(match.range(at: 1), in: code) else { return nil }
                    let shown = String(code[inner])
                    let letters = shownLetters(shown)
                    guard letters.count >= 3, letters == letters.uppercased(), shown != "PRO" else { return nil }
                    return shown
                }
                guard !caps.isEmpty else { continue }
                let styled = lines[index..<min(index + 3, lines.count)].contains {
                    $0.contains(".mwBadge(") || $0.contains(".blocksLabel()")
                }
                if !styled {
                    let name = file.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
                    offenders.append("\(name):\(index + 1) \(caps.joined(separator: " | "))")
                }
            }
        }
        XCTAssertEqual(offenders, [], "caps text outside a micro-label")
    }
}
