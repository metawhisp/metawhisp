import XCTest

/// ITER-075 step 0, US-0.3 — a global key monitor installed before the
/// Accessibility grant stays dead after it unless it is installed again. Every
/// file that installs one is either re-armed on a grant (AppDelegate's
/// `rearmGlobalKeys` and the layout fix's own start) or installs its monitor
/// afresh each time it is shown. A new one fails this test until someone
/// decides which.
final class GlobalKeyMonitorGuardTests: XCTestCase {

    private var repoRoot: URL {
        // …/Tests/MetaWhispTests/Guards/GlobalKeyMonitorGuardTests.swift → repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private let rearmedOnGrant = ["HotkeyService.swift", "ScreenAgentInboxHotkey.swift", "LayoutSwitchController.swift"]
    private let installedEachShow = ["FloatingVoiceWindowController.swift"]

    func testEveryGlobalKeyMonitorComesBackAfterALateGrant() throws {
        let pattern = try NSRegularExpression(
            pattern: #"addGlobalMonitorForEvents\(\s*matching:[^)]*\.(keyDown|keyUp|flagsChanged)"#)
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
        XCTAssertEqual(found, Set(rearmedOnGrant + installedEachShow))
    }
}
