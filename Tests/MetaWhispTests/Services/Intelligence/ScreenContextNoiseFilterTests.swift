import XCTest
@testable import MetaWhisp

/// ITER-042 (cheap hypothesis) — the app's OWN window OCR is a feedback loop:
/// it captures the assistant's previous answer and re-feeds it as if it were a
/// fact on screen (verified: `Self`'s name + prior answers leak via `MetaWhisp`
/// app OCR). It must be dropped from chat screen-context regardless of question
/// type. Everything else (real comms, browsers, IDEs) is kept — they are genuine
/// activity signal.
final class ScreenContextNoiseFilterTests: XCTestCase {

    func test_ownWindow_isFiltered() {
        XCTAssertTrue(ScreenContextNoiseFilter.isOwnWindow(appName: "MetaWhisp", ownAppName: "MetaWhisp"))
    }

    func test_ownWindow_caseAndWhitespaceInsensitive() {
        XCTAssertTrue(ScreenContextNoiseFilter.isOwnWindow(appName: "  metawhisp ", ownAppName: "MetaWhisp"))
        XCTAssertTrue(ScreenContextNoiseFilter.isOwnWindow(appName: "METAWHISP", ownAppName: "metawhisp"))
    }

    func test_realApps_areKept() {
        for app in ["Telegram", "Mattermost", "Google Chrome", "Arc", "Safari",
                    "Xcode", "Finder", "zoom.us", "WhatsApp", "ChatGPT", "Claude"] {
            XCTAssertFalse(ScreenContextNoiseFilter.isOwnWindow(appName: app, ownAppName: "MetaWhisp"),
                           "\(app) must NOT be treated as own-window noise")
        }
    }

    func test_emptyAppName_isNotOwnWindow() {
        XCTAssertFalse(ScreenContextNoiseFilter.isOwnWindow(appName: "", ownAppName: "MetaWhisp"))
    }

    func test_emptyOwnAppName_neverMatches() {
        // Defensive: if the bundle name can't be resolved, don't accidentally
        // filter every empty-appName row.
        XCTAssertFalse(ScreenContextNoiseFilter.isOwnWindow(appName: "", ownAppName: ""))
        XCTAssertFalse(ScreenContextNoiseFilter.isOwnWindow(appName: "Telegram", ownAppName: ""))
    }
}
