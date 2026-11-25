import XCTest
@testable import MetaWhisp

/// ITER-087 — a selected tab, chip, tile or row looks the same everywhere because one modifier draws it
/// (`mwSelectable`): in the dark look the user's accent tinted with a ring, in the light look a raised white pill.
/// Before the new look fourteen views hand-rolled a selected fill (`isSelected ? MW.elevated : .clear` and a stroke)
/// and five drew system materials that read grey on the wall. This scans the SOURCE of the main window, the popover
/// and the shared primitives so neither comes back. Onboarding, the post-update intro and the floating recording
/// surfaces keep their own look (owner, 2026-11-25) and are not scanned.
final class SelectionLookGuardTests: XCTestCase {
    private var repoRoot: URL {
        // …/Tests/MetaWhispTests/Guards/SelectionLookGuardTests.swift → repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// The source without its line comments: only code counts.
    private func code(of url: URL) throws -> String {
        let source = try String(contentsOf: url, encoding: .utf8)
        return source.components(separatedBy: "\n")
            .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line }
            .joined(separator: "\n")
    }

    /// The window's screens, the popover and the shared primitives.
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
        files.append(repoRoot.appendingPathComponent("Views/Components/GlassPrimitives.swift"))
        files.append(repoRoot.appendingPathComponent("Helpers/DesignSystem.swift"))
        return files
    }

    private func offenders(_ patterns: [String]) throws -> [String] {
        let files = try scannedFiles()
        XCTAssertGreaterThan(files.count, 25, "the guard must read the views — path resolution broke")
        return try files.flatMap { file -> [String] in
            let source = try code(of: file)
            let name = file.path.replacingOccurrences(of: repoRoot.path + "/", with: "")
            return patterns.filter { source.contains($0) }.map { "\(name): \($0)" }
        }
    }

    /// A hand-rolled selection, line by line: a state picking a fill or stroke against clear or the plain border.
    func testNoViewHandRollsASelectedFill() throws {
        XCTAssertEqual(try offenders(["MW.selectFill", "MW.selectRim"]), [], "a selection goes through mwSelectable")
        let handRolled = try NSRegularExpression(pattern:
            #"\? (MW\.elevated|Color\.white|\.white|MW\.idle|MW\.accent)(\.opacity\([0-9.]+\))? : (\.clear|Color\.clear|MW\.border)"#)
        var found: [String] = []
        for file in try scannedFiles() {
            let lines = try code(of: file).components(separatedBy: "\n")
            for (index, line) in lines.enumerated()
            where handRolled.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                found.append("\(file.path.replacingOccurrences(of: repoRoot.path + "/", with: "")):\(index + 1)")
            }
        }
        XCTAssertEqual(found, [], "a selection goes through mwSelectable")
    }

    /// Owner, 2026-11-25: "in Violet there must be no green; green only in Green". A status in the window
    /// or the popover (ready, active, pro, installed) is drawn in the user's accent (`MW.ok`), never a fixed green.
    /// The recording indicator and onboarding keep their own green (decision 4) and are not scanned.
    func testNoWindowStatusIsAFixedGreen() throws {
        // The design system is where colours are defined; everywhere else draws with its tokens.
        let found = try offenders(["MW.idle", "Color.green", "MW.postProcess", "Color.accentColor", "Color(red:"])
            .filter { !$0.hasPrefix("Helpers/DesignSystem.swift") }
        XCTAssertEqual(found, [],
                       "a status in the window takes the accent; macOS's own accent (blue) never stands in for it")
    }

    func testNoWindowSurfaceIsASystemMaterial() throws {
        XCTAssertEqual(try offenders(["ultraThinMaterial", "thinMaterial", "regularMaterial", "thickMaterial"]), [],
                       "system materials read grey on the wall; surfaces come from the palette")
    }
}
