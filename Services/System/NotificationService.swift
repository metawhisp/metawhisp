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
                // User clicked the notification — bring app to foreground + open Insights
                NSApp.activate(ignoringOtherApps: true)

                // Advice notifications deprecated — Tasks tab replaces the surface (spec://BACKLOG#sidebar-reorg).
                NotificationCenter.default.post(
                    name: .switchMainTab,
                    object: MainWindowView.SidebarTab.tasks
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
