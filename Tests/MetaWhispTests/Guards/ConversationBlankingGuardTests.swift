import XCTest

/// ITER-075 step 1 (1.6) — nothing clears a conversation's title or overview to
/// force a new run: the generator's regeneration mode asks for the full path
/// outright. Three backfills used to clear the fields and save before the run,
/// and a quit mid-pass left a conversation blank for good (2026-09-22).
final class ConversationBlankingGuardTests: XCTestCase {

    private var repoRoot: URL {
        // …/Tests/MetaWhispTests/Guards/ConversationBlankingGuardTests.swift → repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Every folder with app code except Models, whose initializers start the
    /// fields empty. A folder that disappears fails the guard.
    private let folders = ["App", "Services", "Views", "Helpers"]

    /// The file with `//` comments removed. A `//` inside a string literal
    /// ("https://…") is code and stays.
    private func code(of source: String) -> String {
        source.components(separatedBy: "\n").map { line -> String in
            var inString = false
            var escaped = false
            var previous: Character = " "
            for (offset, char) in line.enumerated() {
                if inString {
                    if escaped {
                        escaped = false
                    } else if char == "\\" {
                        escaped = true
                    } else if char == "\"" {
                        inString = false
                    }
                } else if char == "\"" {
                    inString = true
                } else if char == "/" && previous == "/" {
                    return String(line.prefix(offset - 1))
                }
                previous = char
            }
            return line
        }.joined(separator: "\n")
    }

    private let blankingPattern = #"\.(title|overview)\s*=\s*(nil|\.none)\b"#

    /// The guard sees what it forbids, and nothing else.
    func testTheGuardSeesWhatItForbids() throws {
        let blanking = try NSRegularExpression(pattern: blankingPattern)
        func matches(_ line: String) -> Bool {
            blanking.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }
        XCTAssertTrue(matches("conv.title = nil"))
        XCTAssertTrue(matches("fresh.overview=.none"))
        XCTAssertFalse(matches("conv.title = newTitle"))
        XCTAssertFalse(matches("conv.titleOverride = nil"))
        XCTAssertEqual(code(of: "conv.title = nil // cleared"), "conv.title = nil ",
                       "a comment goes, the code stays")
        XCTAssertEqual(code(of: "// conv.title = nil"), "")
    }

    func testNothingClearsATitleOrAnOverviewToForceARun() throws {
        let blanking = try NSRegularExpression(pattern: blankingPattern)
        let fm = FileManager.default
        var scanned = 0
        var offenders: [String] = []
        for folder in folders {
            let base = repoRoot.appendingPathComponent(folder)
            XCTAssertTrue(fm.fileExists(atPath: base.path), "\(folder)/ is gone — update the folder list")
            guard let files = fm.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in files where url.pathExtension == "swift" {
                let text = code(of: try String(contentsOf: url, encoding: .utf8))
                scanned += 1
                if blanking.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                    offenders.append(url.lastPathComponent)
                }
            }
        }
        XCTAssertGreaterThan(scanned, 200, "the guard must actually scan the sources")
        XCTAssertEqual(offenders, [], "ask generate(isRegeneration: true) instead of clearing the fields first")
    }
}
