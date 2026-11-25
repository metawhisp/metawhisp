import XCTest
@testable import MetaWhisp

/// ITER-087 — the window's wall (`PageWash`) is the one ground of the app's surfaces. Before the new look three
/// screens covered it with an opaque `MW.bg`, and the popover and two sheets painted that flat grey as their own
/// ground. This scans the SOURCE so no screen puts a flat ground back without failing `swift test`. Onboarding keeps
/// its own look (owner, 2026-11-25), so its folder is the one exception.
final class WindowWallGuardTests: XCTestCase {
    private var repoRoot: URL {
        // …/Tests/MetaWhispTests/Guards/WindowWallGuardTests.swift → repo root
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

    private func viewFiles() throws -> [URL] {
        let views = repoRoot.appendingPathComponent("Views")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: views, includingPropertiesForKeys: nil))
        return walker.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && !$0.path.contains("/Views/Windows/Onboarding/") }
    }

    func testNoViewPaintsTheFlatGroundOverTheWall() throws {
        let files = try viewFiles()
        XCTAssertGreaterThan(files.count, 50, "the guard must read the views — path resolution broke")
        let painters = try files.filter { try code(of: $0).contains(".background(MW.bg)") }
            .map { $0.path.replacingOccurrences(of: repoRoot.path + "/", with: "") }
        XCTAssertEqual(painters, [], "these views paint a flat ground over the wall")
    }

    func testTheSurfacesWithoutAWallStandOnIt() throws {
        for path in ["Views/MenuBar/MenuBarView.swift", "Views/Windows/AboutMeView.swift",
                     "Views/Components/AppPickerView.swift", "Views/Windows/GoalsView.swift",
                     "Views/Windows/MemoriesView.swift"] {
            let source = try code(of: repoRoot.appendingPathComponent(path))
            XCTAssertTrue(source.contains(".background(PageWash())"), "\(path) must stand on the wall")
        }
    }
}
