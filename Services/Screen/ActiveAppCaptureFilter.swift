import Foundation

/// AUD-022 fix — decide which windows to EXCLUDE from a screen capture so the
/// screenshot contains only the front application's content.
///
/// Before this, `ScreenContextService.captureScreenshot` filtered the whole
/// display with `excludingWindows: []` — it screenshotted EVERYTHING, including a
/// password manager, private chat or token window visible beside the focused
/// app, then labeled the OCR with only the front app. That bypassed the
/// front-app blacklist and pushed unrelated sensitive text into SwiftData and
/// cloud prompts.
///
/// Excluding every window not owned by the front app (rather than picking a
/// single "active" window) is intentional: it handles multi-window apps, avoids
/// guessing which window is key, and guarantees no other app's pixels are
/// captured. Pure + unit-tested so the privacy boundary is verifiable without
/// ScreenCaptureKit.
enum ActiveAppCaptureFilter {

    struct WindowRef: Equatable {
        let id: Int
        let ownerPID: Int
    }

    /// IDs of windows to exclude from the capture: everything NOT owned by the
    /// front application (identified by `frontPID`).
    static func windowsToExclude(_ windows: [WindowRef], frontPID: Int) -> [Int] {
        windows.filter { $0.ownerPID != frontPID }.map { $0.id }
    }
}
