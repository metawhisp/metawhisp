import XCTest
@testable import MetaWhisp

/// TDD coverage for `SystemAudioCaptureService.detectCallContext` (2026-04-29).
/// Behavior locked in here AFTER user reported Phase A's strict title-matching
/// for Zoom kept missing real calls (titles like "Personal Meeting Room",
/// "Waiting for host" don't contain "Zoom Meeting"). Result: Zoom + Teams
/// moved back to always-call (bundle match alone fires detection).
@MainActor
final class CallContextDetectionTests: XCTestCase {

    // MARK: - Always-call bundles (bundle match alone is enough)

    func test_zoom_anyTitle_detectedAsCall() {
        // ANY Zoom window — "Zoom Meeting", "Personal Meeting Room",
        // "Waiting for host", even just "Zoom" — should be treated as a call.
        // Trade-off: clicking idle Zoom Workplace home triggers a 5s countdown.
        // Acceptable because missing real calls is far worse than dismissing
        // an unwanted countdown.
        XCTAssertEqual(
            SystemAudioCaptureService.detectCallContext(
                bundleID: "us.zoom.xos", appName: "Zoom",
                windowTitle: "User's Personal Meeting Room"
            ), "Zoom"
        )
        XCTAssertEqual(
            SystemAudioCaptureService.detectCallContext(
                bundleID: "us.zoom.xos", appName: "Zoom",
                windowTitle: "Zoom Meeting"
            ), "Zoom"
        )
        XCTAssertEqual(
            SystemAudioCaptureService.detectCallContext(
                bundleID: "us.zoom.xos", appName: "Zoom",
                windowTitle: ""
            ), "Zoom"
        )
    }

    func test_teams_anyTitle_detectedAsCall() {
        XCTAssertEqual(
            SystemAudioCaptureService.detectCallContext(
                bundleID: "com.microsoft.teams2", appName: "Teams",
                windowTitle: "Daily Standup"
            ), "Teams"
        )
        XCTAssertEqual(
            SystemAudioCaptureService.detectCallContext(
                bundleID: "com.microsoft.teams", appName: "Teams",
                windowTitle: ""
            ), "Teams"
        )
    }

    func test_faceTime_detectedAsCall() {
        XCTAssertEqual(
            SystemAudioCaptureService.detectCallContext(
                bundleID: "com.apple.FaceTime", appName: "FaceTime",
                windowTitle: "FaceTime"
            ), "FaceTime"
        )
    }

    // MARK: - Dual-mode bundles (title indicator REQUIRED)

    func test_slack_withoutHuddle_returnsNil() {
        // Just clicking Slack to read a thread shouldn't trigger detection.
        XCTAssertNil(
            SystemAudioCaptureService.detectCallContext(
                bundleID: "com.tinyspeck.slackmacgap", appName: "Slack",
                windowTitle: "MetaWhisp — #general"
            )
        )
    }

    func test_slack_withHuddle_detectsSlack() {
        XCTAssertEqual(
            SystemAudioCaptureService.detectCallContext(
                bundleID: "com.tinyspeck.slackmacgap", appName: "Slack",
                windowTitle: "Huddle in #general"
            ), "Slack"
        )
    }

    func test_discord_withVoiceConnected_detectsDiscord() {
        XCTAssertEqual(
            SystemAudioCaptureService.detectCallContext(
                bundleID: "com.discord.Discord", appName: "Discord",
                windowTitle: "Voice Connected — #lounge"
            ), "Discord"
        )
    }

    // MARK: - Browser path (Meet / Teams web / Zoom web)

    func test_chrome_withMeetURL_detectsGoogleMeet() {
        XCTAssertEqual(
            SystemAudioCaptureService.detectCallContext(
                bundleID: "com.google.Chrome", appName: "Google Chrome",
                windowTitle: "meet.google.com/abc-defg-hij"
            ), "Google Meet"
        )
    }

    func test_chrome_withMeetEmDash_detectsGoogleMeet() {
        XCTAssertEqual(
            SystemAudioCaptureService.detectCallContext(
                bundleID: "com.google.Chrome", appName: "Google Chrome",
                windowTitle: "Meet – DAILY STANDUP — Some Notes"
            ), "Google Meet"
        )
    }

    func test_arc_withRoomCodeOnly_detectsGoogleMeet() {
        XCTAssertEqual(
            SystemAudioCaptureService.detectCallContext(
                bundleID: "company.thebrowser.Browser", appName: "Arc",
                windowTitle: "abc-defg-hij"
            ), "Google Meet"
        )
    }

    func test_chrome_unrelatedTab_returnsNil() {
        XCTAssertNil(
            SystemAudioCaptureService.detectCallContext(
                bundleID: "com.google.Chrome", appName: "Google Chrome",
                windowTitle: "GitHub - some/repo"
            )
        )
    }

    // MARK: - Negative

    func test_unknownBundle_returnsNil() {
        XCTAssertNil(
            SystemAudioCaptureService.detectCallContext(
                bundleID: "com.example.unknown", appName: "Unknown",
                windowTitle: "Whatever"
            )
        )
    }
}
