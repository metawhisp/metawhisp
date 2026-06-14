import XCTest

/// Regression guard for the recurring "click a button → I'm thrown to another
/// Space/display" bug. Root cause every recurrence: an aggressive
/// `NSApp.activate(ignoringOtherApps: true)` in a UI or notification handler,
/// which yanks the user to the main window's *bound* Space instead of bringing
/// the window to the user (see `MainWindowController.swift` for the documented
/// rule). It has regressed before (2026-05-10 reversion; 2026-06 missed
/// file-panel + notification-tap sites).
///
/// This test scans the `App/`, `Views/` and `Services/` source trees and fails
/// if the aggressive form reappears. Fix by using plain `NSApp.activate()` —
/// or, when the app isn't frontmost (e.g. the web sign-in deep-link handler in
/// `App/AppDelegate.swift`), by surfacing the result as a banner instead of
/// force-activating a window onto the user's Space. Sanctioned exceptions are
/// the allowlist below.
final class WindowActivationGuardTests: XCTestCase {

    /// Files permitted to keep the aggressive form.
    private static let allowlist: Set<String> = [
        "OnboardingWindowController.swift", // first launch — app not yet frontmost
    ]

    func testNoAggressiveActivateInUIOrServices() throws {
        let root = try Self.repoRoot()
        var offenders: [String] = []
        for dir in ["App", "Views", "Services"] {
            let base = root.appendingPathComponent(dir, isDirectory: true)
            guard let walker = FileManager.default.enumerator(
                at: base, includingPropertiesForKeys: nil
            ) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                if Self.allowlist.contains(url.lastPathComponent) { continue }
                let normalized = try String(contentsOf: url, encoding: .utf8)
                    .replacingOccurrences(of: " ", with: "")
                if normalized.contains("ignoringOtherApps:true") {
                    offenders.append(url.lastPathComponent)
                }
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "Aggressive `NSApp.activate(ignoringOtherApps: true)` found in "
            + "\(offenders.sorted()). It throws the user to the main window's "
            + "bound Space/display. Use plain `NSApp.activate()` — see "
            + "MainWindowController.swift."
        )
    }

    /// Walk up from this source file to the package root (the dir with Package.swift).
    private static func repoRoot() throws -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fm = FileManager.default
        for _ in 0..<12 {
            if fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        throw XCTSkip("Could not locate Package.swift from \(#filePath); source-tree guard skipped.")
    }
}
