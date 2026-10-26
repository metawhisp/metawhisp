import XCTest

/// ITER-075 step 0, US-0.1 — every path, keychain service, log file and URL
/// scheme that names "this copy of MetaWhisp" comes from `AppIdentity`, so a
/// test build (the Dev app) cannot reach the owner's store, secrets or log
/// through a literal typed again somewhere else.
final class IdentityLiteralGuardTests: XCTestCase {

    private var repoRoot: URL {
        // …/Tests/MetaWhispTests/Guards/IdentityLiteralGuardTests.swift → repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Every folder with app code (Package.swift: the app target is ".", minus
    /// its excludes) and the MCP tool. A folder that disappears fails the
    /// guard instead of silently shrinking what it checks.
    private let folders = ["App", "Services", "Models", "Views", "Helpers", "Sources"]

    /// Files allowed to spell the production values out.
    private let allowed = [
        "/Services/System/AppIdentity.swift",   // the one owner of the values
        "/Sources/MetaWhispMCP/main.swift",     // the MCP tool reads the owner's snapshot by design
    ]

    /// Matched across line breaks, so a call split over lines still counts.
    private let banned: [(pattern: String, names: String)] = [
        (#""com\.metawhisp\.secrets""#, "the keychain service"),
        (#"MetaWhisp\.store"#, "the store file"),
        (#"MetaWhisp\.log"#, "the log file"),
        (#"appendingPathComponent\(\s*"MetaWhisp"#, "the support folder"),
        (#"appending\(\s*(path|component):\s*"MetaWhisp"#, "the support folder"),
        (#"Application Support/MetaWhisp"#, "the support folder"),
        (#"ModelConfiguration\(\s*"MetaWhisp"#, "the store name"),
        (#"==\s*"metawhisp""#, "the URL scheme"),
        (#""metawhisp"\s*=="#, "the URL scheme"),
    ]

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

    func testIdentityLiteralsLiveOnlyInAppIdentity() throws {
        let rules = try banned.map { (try NSRegularExpression(pattern: $0.pattern), $0.names) }
        let fm = FileManager.default
        var scanned = 0
        for folder in folders {
            let base = repoRoot.appendingPathComponent(folder)
            XCTAssertTrue(fm.fileExists(atPath: base.path), "\(folder)/ is gone — update the folder list")
            guard let files = fm.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in files where url.pathExtension == "swift" {
                guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
                scanned += 1
                if allowed.contains(where: { url.path.hasSuffix($0) }) { continue }
                let text = code(of: source)
                for (regex, names) in rules {
                    for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                        guard let range = Range(match.range, in: text) else { continue }
                        let line = text[..<range.lowerBound].filter { $0 == "\n" }.count + 1
                        XCTFail("\(url.lastPathComponent):\(line) spells out \(names) — take it from AppIdentity.current")
                    }
                }
            }
        }
        XCTAssertGreaterThan(scanned, 250, "the guard must actually scan the sources")
    }
}
