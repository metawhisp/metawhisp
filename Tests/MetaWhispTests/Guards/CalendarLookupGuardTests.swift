import XCTest

/// ITER-075 step 1 (1.1) — EventKit answers an identifier lookup for a
/// recurring series with the series' FIRST occurrence, whose end is months
/// past; that ended recorded meetings one second in. No live code may look an
/// event up by its identifier: the calendar tick's own occurrences are used.
final class CalendarLookupGuardTests: XCTestCase {

    private var repoRoot: URL {
        // …/Tests/MetaWhispTests/Guards/CalendarLookupGuardTests.swift → repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Every folder with app code (Package.swift: the app target is ".", minus
    /// its excludes). A folder that disappears fails the guard.
    private let folders = ["App", "Services", "Models", "Views", "Helpers"]

    /// Dead since 2026-05-12 (ObsidianExporter replaced it) and still holding
    /// the lookup. It is allowed only while no code refers to it; deleting it
    /// is the owner's call.
    private let dead = "MeetingObsidianWriter"

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

    func testNoLiveCodeLooksAnEventUpByItsIdentifier() throws {
        // Matched across line breaks, with or without a receiver.
        let lookup = try NSRegularExpression(
            pattern: #"\b(event|calendarItem)\s*\(\s*(withIdentifier|forIdentifier)\s*:"#)
        let fm = FileManager.default
        var scanned = 0
        var offenders: [String] = []
        var deadIsReferenced = false
        for folder in folders {
            let base = repoRoot.appendingPathComponent(folder)
            XCTAssertTrue(fm.fileExists(atPath: base.path), "\(folder)/ is gone — update the folder list")
            guard let files = fm.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in files where url.pathExtension == "swift" {
                let text = code(of: try String(contentsOf: url, encoding: .utf8))
                scanned += 1
                let name = url.deletingPathExtension().lastPathComponent
                if name != dead && text.contains(dead) { deadIsReferenced = true }
                if lookup.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                    offenders.append(name)
                }
            }
        }
        XCTAssertGreaterThan(scanned, 250, "the guard must actually scan the sources")
        XCTAssertEqual(offenders.filter { $0 != dead || deadIsReferenced }, [],
                       "look the occurrence up from the calendar tick, never by its identifier")
    }
}
