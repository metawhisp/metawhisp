import AppKit
import ApplicationServices
import XCTest
@testable import MetaWhisp

/// The fill's eyes on a real Chrome window (2026-10-13). Live, by voice, «fill this page» reached `doHere` and the
/// eyes took Chrome's own toolbar — its site-information, menu and tab-search pop-ups — for the page's fields:
/// asked with `AXManualAccessibility`, Chrome 154 showed no web area for 10 s. A Chrome of the test's own — a fresh
/// profile in a temporary folder, a page from a file — is opened behind the user's work and never brought forward;
/// nothing is typed or pressed. Runs only with METAWHISP_LIVE_CHROME_AX=1, never in the gate: a fresh Chrome
/// sometimes never shows its page to the Accessibility API at all (1 in 5-8 runs, 2026-10-13) — 4 of 5 passed after
/// the fix, 0 of 1 before it. Skipped without Chrome or without the Accessibility permission.
@MainActor
final class HereEyesChromeLiveTests: XCTestCase {

    private static let chromeApp = URL(fileURLWithPath: "/Applications/Google Chrome.app")

    private static let form = """
    <!doctype html><html><head><meta charset="utf-8"><title>Edit your profile</title></head><body>
    <h1>Edit your profile</h1>
    <form>
      <label for="first">First Name</label> <input id="first" type="text">
      <label for="email">Email</label> <input id="email" type="email">
      <label for="pw">Password</label> <input id="pw" type="password">
    </form></body></html>
    """

    /// A Chrome of the test's own showing `form`, its window up with the page loaded — as the user's is when they
    /// ask; the caller ends it.
    private func chrome(in folder: URL) async throws -> NSRunningApplication {
        let page = folder.appendingPathComponent("form.html")
        try Self.form.write(to: page, atomically: true, encoding: .utf8)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.createsNewApplicationInstance = true
        config.arguments = ["--user-data-dir=\(folder.appendingPathComponent("profile").path)", "--no-first-run",
                            "--no-default-browser-check", "--disable-sync", "--new-window", page.absoluteString]
        let chrome = try await NSWorkspace.shared.openApplication(at: Self.chromeApp, configuration: config)
        let app = AXUIElementCreateApplication(chrome.processIdentifier)
        for _ in 0..<150 {
            var windows: AnyObject?
            if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
               let shown = windows as? [AXUIElement], shown.contains(where: { window in
                   var title: AnyObject?
                   return AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success
                       && (title as? String)?.hasPrefix("Edit your profile") == true
               }) { return chrome }
            try await Task.sleep(for: .milliseconds(100))
        }
        chrome.terminate()
        throw XCTSkip("Chrome showed no window in 15 s")
    }

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("here-chrome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// The app's eyes on Chrome see the page's fields — the password left alone — and none of Chrome's own controls.
    func testTheEyesSeeAChromePagesFieldsNotItsToolbar() async throws {
        guard ProcessInfo.processInfo.environment["METAWHISP_LIVE_CHROME_AX"] == "1" else {
            throw XCTSkip("live: METAWHISP_LIVE_CHROME_AX=1 opens a visible Chrome window")
        }
        guard FileManager.default.fileExists(atPath: Self.chromeApp.path) else { throw XCTSkip("no Chrome") }
        guard AXIsProcessTrusted() else { throw XCTSkip("no Accessibility permission") }
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let chrome = try await chrome(in: folder)
        defer { chrome.terminate() }

        let seen = await DoHere.read(chrome.processIdentifier)
        let look = try XCTUnwrap(seen)

        XCTAssertEqual(look.fields.map(\.label), ["First Name", "Email"])
        XCTAssertEqual(look.title, "Edit your profile")
    }
}
