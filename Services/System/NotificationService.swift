import AppKit
import Foundation
import UserNotifications

/// Posts macOS system notifications for AdviceItems.
/// Handles click → open Insights tab.
///
/// Implements spec://intelligence/FEAT-0003#notifications
@MainActor
final class NotificationService: NSObject, ObservableObject {
    static let shared = NotificationService()

    /// Category for advice notifications (enables custom action handling)
    private static let adviceCategoryID = "com.metawhisp.advice"

    /// Advice items mapped by notification identifier for click handling.
    private var adviceMap: [String: UUID] = [:]

    /// Rate limit: timestamp of last sent notification.
    private var lastSentAt: Date?
    private static let minInterval: TimeInterval = 60 // 1 per minute

    @Published var authorizationStatus: UNAuthorizationStatus = .notDetermined

    override private init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        setupCategories()
        refreshAuthorizationStatus()
    }

    // MARK: - Setup

    private func setupCategories() {
        let category = UNNotificationCategory(
            identifier: Self.adviceCategoryID,
            actions: [],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    private func refreshAuthorizationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                self?.authorizationStatus = settings.authorizationStatus
            }
        }
    }

    // MARK: - Permission

    /// Request notification permission. Returns true if granted.
    @discardableResult
    func requestPermission() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            refreshAuthorizationStatus()
            NSLog("[Notifications] Permission granted: %@", granted ? "YES" : "NO")
            return granted
        } catch {
            NSLog("[Notifications] Permission request failed: %@", error.localizedDescription)
            return false
        }
    }

    var hasPermission: Bool {
        authorizationStatus == .authorized || authorizationStatus == .provisional
    }

    // MARK: - Post Advice

    /// Post a notification for a newly-extracted task. Copied from reference
    /// `TaskPromotionService.swift:84-90` — one notification per task, immediate delivery,
    /// no rate limit. Click opens Tasks tab (same handler as advice).
    ///
    /// `source` labels where the task came from (e.g. "Screen", "Voice") — shown as title.
    /// Implements spec://iterations/ITER-005-task-notifications#scope
    func postNewTask(_ task: TaskItem, source: String) {
        guard hasPermission else {
            NSLog("[Notifications] No permission — skipping task notification (still in Tasks tab)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = source.isEmpty ? "New task" : "New task from \(source)"
        content.body = String(task.taskDescription.prefix(200))
        content.sound = .default
        content.categoryIdentifier = Self.adviceCategoryID  // reuse — same click → Tasks behavior

        let id = "com.metawhisp.task.\(task.id.uuidString)"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { err in
            if let err {
                NSLog("[Notifications] ❌ Task notification failed: %@", err.localizedDescription)
            } else {
                NSLog("[Notifications] ✅ Posted task notification: %@", String(task.taskDescription.prefix(60)))
            }
        }
    }

    /// Post a call-detection notification. Not rate-limited — call events are
    /// already debounced at source (fire only on state change in ScreenContextService).
    ///
    /// Implements spec://iterations/ITER-002-call-detection#notification
    func postCallDetected(appName: String, autoStart: Bool) {
        guard hasPermission else {
            NSLog("[Notifications] No permission — skipping call notification")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "\(appName) detected"
        content.body = autoStart
            ? "Recording starts in 5 seconds…"
            : "Tap the menu bar to start recording."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "com.metawhisp.call.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { err in
            if let err {
                NSLog("[Notifications] ❌ Call notification failed: %@", err.localizedDescription)
            } else {
                NSLog("[Notifications] ✅ Call notification posted: %@ (autoStart=%@)",
                      appName, autoStart ? "YES" : "NO")
            }
        }
    }

    /// Notification fired when MeetingRecorder auto-stops itself (ITER-012).
    /// Reasons: call window closed, prolonged silence, or max-duration cap.
    /// User-facing copy explains WHY so the recording vanishing isn't surprising.
    func postMeetingAutoStopped(reason: MeetingRecorder.AutoStopReason) {
        guard hasPermission else { return }
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
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "com.metawhisp.meeting.autostop.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req) { err in
            if let err {
                NSLog("[Notifications] ❌ Auto-stop notif failed: %@", err.localizedDescription)
            }
        }
    }

    /// Post the per-meeting recap notification (ITER-012). Sent after extractors
    /// finish so body counts of tasks/memories are accurate. Click → Library tab.
    /// `conversationId` lets future iterations deep-link to the specific row.
    func postMeetingRecap(title: String, overview: String, taskCount: Int,
                          memoryCount: Int, conversationId: UUID) {
        guard hasPermission else { return }
        let content = UNMutableNotificationContent()
        content.title = "Meeting recap: \(title.isEmpty ? "untitled" : title)"
        var body = String(overview.prefix(140))
        var counts: [String] = []
        if taskCount > 0  { counts.append("\(taskCount) task\(taskCount == 1 ? "" : "s")") }
        if memoryCount > 0 { counts.append("\(memoryCount) memor\(memoryCount == 1 ? "y" : "ies")") }
        if !counts.isEmpty {
            if !body.isEmpty { body += "\n" }
            body += counts.joined(separator: " · ")
        }
        if body.isEmpty { body = "Transcript saved." }
        content.body = body
        content.sound = .default
        content.userInfo = ["conversationId": conversationId.uuidString,
                            "target": "library"]
        // Reuse advice category so click routing → tab switch works through existing handler.
        content.categoryIdentifier = Self.adviceCategoryID

        let req = UNNotificationRequest(
            identifier: "com.metawhisp.meeting.recap.\(conversationId.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req) { err in
            if let err {
                NSLog("[Notifications] ❌ Recap notif failed: %@", err.localizedDescription)
            } else {
                NSLog("[Notifications] ✅ Recap posted: '%@' (%d tasks, %d memories)",
                      title, taskCount, memoryCount)
            }
        }
    }

    /// Post a notification for a newly-generated advice item.
    /// Rate-limited to 1 per minute.
    func postAdvice(_ advice: AdviceItem) {
        // Rate limit
        if let last = lastSentAt, Date().timeIntervalSince(last) < Self.minInterval {
            NSLog("[Notifications] Rate limited — skipping (last sent %.0fs ago)",
                  Date().timeIntervalSince(last))
            return
        }

        guard hasPermission else {
            NSLog("[Notifications] No permission — skipping notification (advice still in Insights tab)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = advice.category.capitalized
        content.body = String(advice.content.prefix(200))
        content.sound = .default
        content.categoryIdentifier = Self.adviceCategoryID

        let id = UUID().uuidString
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)

        adviceMap[id] = advice.id

        UNUserNotificationCenter.current().add(request) { [weak self] error in
            Task { @MainActor in
                if let error {
                    NSLog("[Notifications] ❌ Post failed: %@", error.localizedDescription)
                    self?.adviceMap.removeValue(forKey: id)
                } else {
                    NSLog("[Notifications] ✅ Posted advice notification: %@", advice.category)
                    self?.lastSentAt = Date()
                }
            }
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationService: UNUserNotificationCenterDelegate {
    /// Show notification banner even when app is in foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }

    /// Handle click / dismiss.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = response.notification.request.identifier

        Task { @MainActor in
            let adviceID = self.adviceMap[id]
            self.adviceMap.removeValue(forKey: id)

            switch response.actionIdentifier {
            case UNNotificationDefaultActionIdentifier:
                // User clicked the notification — bring app to foreground.
                NSApp.activate(ignoringOtherApps: true)

                // Route to the right tab based on notification's userInfo.
                // Default: Tasks (advice/task/legacy). Meeting recap: Library.
                let userInfo = response.notification.request.content.userInfo
                let target = userInfo["target"] as? String ?? ""
                let destinationTab: MainWindowView.SidebarTab = {
                    switch target {
                    case "library": return .library
                    case "dashboard": return .dashboard
                    default: return .tasks
                    }
                }()
                NotificationCenter.default.post(
                    name: .switchMainTab,
                    object: destinationTab
                )

                // Signal to AdviceService / InsightsView to mark this item as read
                if let adviceID {
                    NotificationCenter.default.post(
                        name: .markAdviceAsRead,
                        object: adviceID
                    )
                }

            case UNNotificationDismissActionIdentifier:
                // User swiped away — no action needed
                break

            default:
                break
            }

            completionHandler()
        }
    }
}

// MARK: - Notification.Name

extension Notification.Name {
    static let markAdviceAsRead = Notification.Name("MetaWhisp.markAdviceAsRead")
}
