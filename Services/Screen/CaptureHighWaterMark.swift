import Foundation

/// ITER-064A.3 — "which window have we already captured?"
///
/// The capture loop polls on an interval and only does work when the focused
/// window differs from the last one. That makes this mark the retry policy:
/// whatever it records is a window the loop will not look at again.
///
/// It used to be two loose `lastAppName`/`lastWindowTitle` fields updated right
/// after the change check and before the capture await, so a capture that then
/// failed still consumed the change. Advancing only on an accepted frame keeps
/// a failed attempt eligible for the next poll.
struct CaptureHighWaterMark {

    private var appName: String?
    private var windowTitle: String?

    /// True when this window has not been captured yet.
    func hasChanged(appName: String, windowTitle: String) -> Bool {
        appName != self.appName || windowTitle != self.windowTitle
    }

    /// Record an accepted frame. Pass the window the frame actually came from —
    /// the user can switch apps during the capture await, and the frame that
    /// came back is the one that was captured.
    mutating func accept(appName: String, windowTitle: String) {
        self.appName = appName
        self.windowTitle = windowTitle
    }
}
