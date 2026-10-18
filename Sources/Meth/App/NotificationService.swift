import Foundation
@preconcurrency import UserNotifications
import os.log
import MethCore

private let logger = Logger(subsystem: "com.meth.app", category: "NotificationService")

@MainActor
public final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = NotificationService()

    private static let sessionCategoryIdentifier = "com.meth.notification.session"
    private static let extend15ActionIdentifier = "com.meth.notification.action.extend15"
    private static let extend60ActionIdentifier = "com.meth.notification.action.extend60"
    private static let stopActionIdentifier = "com.meth.notification.action.stop"
    private static let expiringWarningNotificationID = "com.meth.notification.expiringWarning"
    private static let automaticStopNotificationID = "com.meth.notification.automaticStop"

    private let sessionManager: SessionManager
    private var isConfigured = false

    public init(sessionManager: SessionManager? = nil) {
        self.sessionManager = sessionManager ?? SessionManager.shared
        super.init()
    }

    public func configure() {
        guard !isConfigured, Bundle.main.bundleURL.pathExtension == "app" else { return }
        isConfigured = true

        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let extend15 = UNNotificationAction(
            identifier: Self.extend15ActionIdentifier,
            title: "+15 Minutes",
            options: []
        )
        let extend60 = UNNotificationAction(
            identifier: Self.extend60ActionIdentifier,
            title: "+1 Hour",
            options: []
        )
        let stop = UNNotificationAction(
            identifier: Self.stopActionIdentifier,
            title: "Stop Session",
            options: [.destructive]
        )
        let category = UNNotificationCategory(
            identifier: Self.sessionCategoryIdentifier,
            actions: [extend15, extend60, stop],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    public func requestAuthorizationIfNeeded() {
        guard Bundle.main.bundleURL.pathExtension == "app", sessionManager.notificationsEnabled else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    logger.warning("Notification authorization request failed: \(error.localizedDescription)")
                } else {
                    logger.info("Notification authorization granted: \(granted)")
                }
            }
        }
    }

    public func scheduleExpirationWarning(remainingSeconds: TimeInterval?) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.expiringWarningNotificationID])

        guard sessionManager.notificationsEnabled,
              let remaining = remainingSeconds,
              remaining > 330 else { return }

        let fireDelay = remaining - 300
        let content = UNMutableNotificationContent()
        content.title = "Keep-Awake Session Ending Soon"
        content.body = "Your Meth session will end in 5 minutes."
        content.sound = .default
        content.categoryIdentifier = Self.sessionCategoryIdentifier

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fireDelay, repeats: false)
        let request = UNNotificationRequest(
            identifier: Self.expiringWarningNotificationID,
            content: content,
            trigger: trigger
        )
        center.add(request) { error in
            if let error {
                logger.warning("Failed to schedule expiration warning notification: \(error.localizedDescription)")
            }
        }
    }

    public func cancelExpirationWarning() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.expiringWarningNotificationID])
        center.removeDeliveredNotifications(withIdentifiers: [Self.expiringWarningNotificationID])
    }

    public func postAutomaticStopNotification(reason: String) {
        guard Bundle.main.bundleURL.pathExtension == "app", sessionManager.notificationsEnabled else { return }
        let center = UNUserNotificationCenter.current()

        let content = UNMutableNotificationContent()
        content.title = "Session Stopped Automatically"
        content.body = reason
        content.sound = .defaultCritical

        let request = UNNotificationRequest(
            identifier: Self.automaticStopNotificationID,
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                logger.warning("Failed to deliver automatic stop notification: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionIdentifier = response.actionIdentifier
        Task { @MainActor in
            switch actionIdentifier {
            case Self.extend15ActionIdentifier:
                await SessionManager.shared.extendSession(by: SessionDuration.fifteenMinutes)
            case Self.extend60ActionIdentifier:
                await SessionManager.shared.extendSession(by: SessionDuration.oneHour)
            case Self.stopActionIdentifier:
                await SessionManager.shared.stopSession()
            default:
                break
            }
            completionHandler()
        }
    }
}

