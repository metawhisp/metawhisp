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
        let title = source.isEmpty ? "New task" : "New task from \(source)"
        let note = MWNotification(
            kind: .task,
            title: title,
            body: String(task.taskDescription.prefix(200)),
            onTap: {
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(
                    name: .switchMainTab,
                    object: MainWindowView.SidebarTab.tasks
                )
            }
        )
        MWNotificationStack.shared.push(note)
        NSLog("[Notifications] ✅ Posted task: %@", String(task.taskDescription.prefix(60)))
    }

    /// Call detection — fires once per session per app (CallSessionMachine
    /// dedups upstream, so we don't repeat ourselves here).
    func postCallDetected(appName: String, autoStart: Bool) {
        let body = autoStart
            ? "Recording starts in 5 seconds…"
            : "Tap the menu bar to start recording."
        let note = MWNotification(
            kind: .call,
            title: "\(appName) detected",
            body: body,
            onTap: {
                NSApp.activate(ignoringOtherApps: true)
            }
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
                return ("Recording stopped", "The call window closed — saving transcript.")
            case .silenceTimeout:
                let mins = Int(AppSettings.shared.meetingSilenceStopMinutes)
                return ("Recording stopped", "Silence for \(mins) min — saving transcript.")
            case .maxDurationReached:
                let hrs = Int(AppSettings.shared.meetingMaxDurationMinutes / 60)
                return ("Recording stopped", "Hit \(hrs)h max duration — saving transcript.")
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
        let note = MWNotification(
            kind: .advice,
            title: advice.category.capitalized,
            body: String(advice.content.prefix(200)),
            onTap: {
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(
                    name: .switchMainTab,
                    object: MainWindowView.SidebarTab.tasks
                )
                NotificationCenter.default.post(name: .markAdviceAsRead, object: adviceID)
            }
        )
        MWNotificationStack.shared.push(note)
        lastAdviceAt = Date()
        NSLog("[Notifications] ✅ Posted advice: %@", advice.category)
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
