import XCTest

/// ITER-076 P5 — the Carbon hot key table belongs to one file.
///
/// A second registration would take the combo away from the app's own
/// shortcut: the window server gives the hot key to whoever asks first, and
/// nobody would notice that the meeting shortcut had gone quiet.
final class MeetingHelpHotkeyGuardTests: XCTestCase {

    func testOnlyTheMeetingHelpHotkeyRegistersACarbonHotkey() throws {
        let pattern = try NSRegularExpression(pattern: #"RegisterEventHotKey\s*\("#)
        var found: Set<String> = []
        for folder in ["App", "Services", "Models", "Views", "Helpers"] {
            let base = repoRoot.appendingPathComponent(folder)
            XCTAssertTrue(FileManager.default.fileExists(atPath: base.path), "\(folder)/ is gone — update the list")
            guard let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in files where url.pathExtension == "swift" {
                guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
                if pattern.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil {
                    found.insert(url.lastPathComponent)
                }
            }
        }
        XCTAssertEqual(found, ["MeetingHelpHotkey.swift"])
    }

    /// …/Tests/MetaWhispTests/Guards/MeetingHelpHotkeyGuardTests.swift → the
    /// repository's root.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
