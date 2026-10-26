import XCTest
@testable import MetaWhisp

/// The permission dialog is where the user decides, so it is the one string
/// that has to be true.
///
/// It said: "Screenshots are processed locally and never sent to the cloud."
/// `ScreenAgentProVisionTransport` POSTs `image_b64` — the screenshot, base64 —
/// to `api.metawhisp.com/api/pro/vision` whenever Visual mode is on. The claim
/// was false in the exact dialog where the user grants screen access.
final class PrivacyCopyTests: XCTestCase {

    // Repo-relative: Tests/MetaWhispTests/… → the repository's root.
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // MetaWhispTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root

    private func infoPlist() throws -> [String: Any] {
        let url = root.appendingPathComponent("Resources/Info.plist")
        return try XCTUnwrap(
            try PropertyListSerialization.propertyList(
                from: Data(contentsOf: url), format: nil) as? [String: Any])
    }

    private func screenCaptureUsageDescription() throws -> String {
        try XCTUnwrap(try infoPlist()["NSScreenCaptureUsageDescription"] as? String)
    }

    /// The app's Swift sources, by path from the root, with their text.
    private func appSources() throws -> [(path: String, text: String)] {
        var out: [(String, String)] = []
        for folder in ["App", "Services", "Models", "Views", "Helpers"] {
            let base = root.appendingPathComponent(folder)
            guard let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in files where url.pathExtension == "swift" {
                out.append(("\(folder)/" + url.path.dropFirst(base.path.count + 1), try String(contentsOf: url, encoding: .utf8)))
            }
        }
        XCTAssertFalse(out.isEmpty, "the guard reads the sources")
        return out
    }

    /// The specific sentence that was untrue, pinned so it cannot come back.
    func testThePermissionDialogDoesNotPromiseTheImageStaysOnTheMac() throws {
        let copy = try screenCaptureUsageDescription().lowercased()
        XCTAssertFalse(copy.contains("never sent to the cloud"),
                       "Visual mode sends the screenshot to our proxy")
        XCTAssertFalse(copy.contains("never leave"),
                       "same claim, different words")
    }

    /// Saying less is not the fix either. The dialog has to name the two things
    /// that actually leave: recognised text always, the image only behind a
    /// second switch.
    func testThePermissionDialogNamesWhatLeavesAndWhatDoesNot() throws {
        let copy = try screenCaptureUsageDescription().lowercased()
        XCTAssertTrue(copy.contains("visual mode"),
                      "the image only leaves behind a separate opt-in — say which")
        XCTAssertTrue(copy.contains("text"),
                      "recognised text is what leaves in the ordinary case")
        XCTAssertTrue(copy.contains("saved") || copy.contains("stored"),
                      "screenshots are not kept, and that is worth saying")
    }

    // MARK: - PRD P1 16: only prompts the app can show, in plain words

    /// The system-audio prompt text goes with Core Audio's process taps. Meetings take system audio through
    /// ScreenCaptureKit, under Screen Recording, and nothing taps Core Audio — so the text is gone, and a tap added
    /// later must bring it back.
    func testTheSystemAudioPromptTextIsThereExactlyWhileSomethingTapsCoreAudio() throws {
        let sources = try appSources()
        let taps = sources.filter { $0.text.contains("AudioHardwareCreateProcessTap") || $0.text.contains("CATapDescription") }
        let plist = try infoPlist()
        if taps.isEmpty {
            XCTAssertNil(plist["NSAudioCaptureUsageDescription"], "no feature can show it")
        } else {
            XCTAssertNotNil(plist["NSAudioCaptureUsageDescription"], "a Core Audio tap needs it: \(taps.map(\.path))")
        }
        let meetings = try XCTUnwrap(sources.first { $0.path == "Services/Audio/SystemAudioCaptureService.swift" }?.text)
        XCTAssertTrue(meetings.contains("config.capturesAudio = true"), "meetings' system audio comes from ScreenCaptureKit")
        XCTAssertNotNil(plist["NSScreenCaptureUsageDescription"], "whose permission is Screen Recording")
    }

    /// The Automation prompt comes from the Notes import — the only app MetaWhisp sends Apple Events to; the browser
    /// agent drives Chrome through its debugging port — so its text speaks of Notes, says when, and says the text can
    /// leave, as the screen's does.
    func testTheAutomationPromptSpeaksOfTheNotesImport() throws {
        let sources = try appSources()
        let osascript = sources.filter { $0.text.contains("/usr/bin/osascript") }.map(\.path)
        XCTAssertEqual(osascript, ["Services/Indexing/AppleNotesReaderService.swift"], "the one script runner")
        XCTAssertTrue(sources.allSatisfy { !$0.text.contains("NSAppleScript(") }, "no script run in process")
        for (path, text) in sources {
            for line in text.components(separatedBy: "\n") where line.contains("AutomationPermission.check(bundleID:") {
                XCTAssertTrue(line.contains("\"com.apple.Notes\""), "\(path) asks to drive another app: \(line)")
            }
        }
        let copy = try XCTUnwrap(try infoPlist()["NSAppleEventsUsageDescription"] as? String)
        XCTAssertTrue(copy.contains("Notes"), copy)
        XCTAssertTrue(copy.contains("Settings"), "it says when: once turned on")
        XCTAssertTrue(copy.contains("AI provider"), "the text can leave, as the screen prompt says")
        for word in ["browser", "errand", "tab"] {
            XCTAssertFalse(copy.lowercased().contains(word), "no browser errands: \(word)")
        }
    }
}
