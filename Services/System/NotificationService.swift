import AppKit
import Foundation
import SwiftUI

/// Routes app-side notifications into `MWNotificationStack` (single in-app
/// design, top-right, max 4 visible). Replaces macOS-native UN banners — those
/// were stacked separately by the OS and overlapped our `ProactiveChipWindow`,
/// producing two visually distinct notifications fighting for the same corner.
///
/// We're a menu-bar app, always running, so dropping system banners costs us
/// nothing: the user sees our card immediately or never (we never need
/// "background delivery" semantics that UN provides).
///
/// spec://iterations/ITER-026-notification-unification
@MainActor
final class NotificationService: NSObject, ObservableObject {
    static let shared = NotificationService()

    /// Rate limit on advice cards (which can fire frequently when AI keeps
    /// surfacing things) — same 1-per-minute behaviour as before.
    private var lastAdviceAt: Date?
    private static let adviceMinInterval: TimeInterval = 60

    override private init() { super.init() }

    /// Compatibility shim: previously returned UN authorization. Always true now —
    /// in-app stack doesn't need OS permission.
    var hasPermission: Bool { true }

    /// Compatibility shim — old onboarding flow called this. Now a no-op.
    @discardableResult
    func requestPermission() async -> Bool { true }

    // MARK: - Posters

    /// Notification for a freshly-extracted task. `source` labels the origin
    /// ("Voice", "Screen") so the user knows where the suggestion came from.
    func postNewTask(_ task: TaskItem, source: String) {
        // DND while a meeting is recording — task lands in the post-meeting
        // recap popup, not a live banner. MetaWhisp-only DND, never touches
        // macOS Focus.
        if AppDelegate.shared?.meetingRecorder.isRecording == true {
            NSLog("[Notifications] DND — meeting active, deferring task notify (will land in recap)")
            return
        }
        let title = source.isEmpty ? "Task added" : "Task added from \(source)"
        let note = MWNotification(
            kind: .task,
            title: title,
            body: String(task.taskDescription.prefix(200)),
            onTap: {
                // Space-throw fix (2026-06-10): NSApp.activate() snapped the
                // user to the Space of the app's key window («кидает на первый
                // экран»). openMainWindow re-places the window on the CURRENT
                // Space and switches the tab itself.
                AppDelegate.shared?.openMainWindow(tab: .workspace)
            }
        )
        MWNotificationStack.shared.push(note)
        NSLog("[Notifications] ✅ Posted task: %@", String(task.taskDescription.prefix(60)))
    }

    /// Call detection — fires once per session per app (CallSessionMachine
    /// dedups upstream, so we don't repeat ourselves here).
    func postCallDetected(appName: String, autoStart: Bool) {
        let body = autoStart
            ? "Recording starts in 5 seconds"
            : "Tap the menu bar to start recording"
        let note = MWNotification(
            kind: .call,
            title: "\(appName) call started",
            body: body,
            // Space-throw fix (2026-06-10): the tap did nothing useful —
            // NSApp.activate() only snapped the user to another Space. The
            // card itself already says what to do ("Tap the menu bar…").
            onTap: nil
        )
        MWNotificationStack.shared.push(note)
        NSLog("[Notifications] ✅ Posted call: %@ (autoStart=%@)", appName, autoStart ? "YES" : "NO")
    }

    /// Meeting recorder auto-stopped — explain WHY so the recording vanishing
    /// isn't a surprise (silence timeout / max-duration / call ended).
    func postMeetingAutoStopped(reason: MeetingRecorder.AutoStopReason) {
        let (title, body): (String, String) = {
            switch reason {
            case .callEnded:
                return ("Recording saved", "The call window closed — transcript on the way")
            case .silenceTimeout:
                let mins = Int(AppSettings.shared.meetingSilenceStopMinutes)
                return ("Recording saved", "Silence for \(mins) min — transcript on the way")
            case .maxDurationReached:
                let hrs = Int(AppSettings.shared.meetingMaxDurationMinutes / 60)
                return ("Recording saved", "Hit \(hrs)h max duration — transcript on the way")
            }
        }()
        let note = MWNotification(
            kind: .recordingStopped,
            title: title,
            body: body,
            onTap: nil  // informational only
        )
        MWNotificationStack.shared.push(note)
    }

    /// Advice item — rate-limited (1/min) AND DND-suppressed during meetings.
    func postAdvice(_ advice: AdviceItem) {
        if let last = lastAdviceAt, Date().timeIntervalSince(last) < Self.adviceMinInterval {
            NSLog("[Notifications] Rate limited — skipping advice (last sent %.0fs ago)",
                  Date().timeIntervalSince(last))
            return
        }
        if AppDelegate.shared?.meetingRecorder.isRecording == true {
            NSLog("[Notifications] DND — meeting active, suppressing advice notify")
            return
        }
        let adviceID = advice.id
        // `headline` exists for exactly this — a short punchy line for the
        // card — and the card was showing the filing category instead
        // («Productivity»), which tells the reader nothing about what
        // happened. Legacy rows have no headline; they fall back to the
        // advice itself rather than to a category word.
        let note = MWNotification(
            kind: .advice,
            title: advice.headline ?? String(advice.content.prefix(60)),
            body: String(advice.content.prefix(200)),
            onTap: {
                // Space-throw fix (2026-06-10) — see postNewTask.
                AppDelegate.shared?.openMainWindow(tab: .workspace)
                NotificationCenter.default.post(name: .markAdviceAsRead, object: adviceID)
            },
            sourceApp: advice.sourceApp
        )
        MWNotificationStack.shared.push(note)
        lastAdviceAt = Date()
        NSLog("[Notifications] ✅ Posted advice: %@", advice.category)
    }

    /// Result banner for the web sign-in deep link (`metawhisp://auth`). Replaces
    /// the old force-activate + open-window flow that threw the user onto the
    /// main window's Space/display after signing in from the browser. The
    /// banner's `canJoinAllSpaces` panel surfaces wherever the user currently
    /// is; tapping it opens the app on their terms.
    func postSignInResult(title: String, body: String) {
        let note = MWNotification(
            kind: .signIn,
            title: title,
            body: body,
            onTap: {
                // Space-throw fix (2026-06-10): openMainWindow alone is enough —
                // it orders the window onto the CURRENT Space; NSApp.activate()
                // on top of it re-introduced the Space jump.
                AppDelegate.shared?.openMainWindow()
            }
        )
        MWNotificationStack.shared.push(note)
        NSLog("[Notifications] ✅ Posted sign-in result: %@", title)
    }

    // NOTE: `postMeetingRecap` was deliberately removed. The recap is shown
    // by `MeetingRecapWindow` (top-center, full structured payload) — adding
    // a parallel banner double-notified the user and was the most visible
    // overlap in the top-right corner. spec://iterations/ITER-026
}

// MARK: - Notification.Name

extension Notification.Name {
    static let markAdviceAsRead = Notification.Name("MetaWhisp.markAdviceAsRead")
}
