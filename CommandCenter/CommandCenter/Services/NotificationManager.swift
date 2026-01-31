//
//  NotificationManager.swift
//  OrbitDock
//

import Foundation
import UserNotifications

@Observable
class NotificationManager {
    static let shared = NotificationManager()

    private var notifiedSessionIds: Set<String> = []
    private var isAuthorized = false

    private init() {
        requestAuthorization()
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            DispatchQueue.main.async {
                self.isAuthorized = granted
                if let error = error {
                    print("Notification authorization error: \(error)")
                }
            }
        }
    }

    /// Get the configured notification sound from user preferences
    private var configuredSound: UNNotificationSound? {
        let soundName = UserDefaults.standard.string(forKey: "notificationSound") ?? "default"

        switch soundName {
        case "none":
            return nil
        case "default":
            return .default
        default:
            return UNNotificationSound(named: UNNotificationSoundName(rawValue: soundName))
        }
    }

    /// Check if notifications are enabled in user preferences
    private var notificationsEnabled: Bool {
        // Default to true if not set
        if UserDefaults.standard.object(forKey: "notificationsEnabled") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "notificationsEnabled")
    }

    func notifyNeedsAttention(session: Session) {
        guard isAuthorized else { return }
        guard notificationsEnabled else { return }
        guard !notifiedSessionIds.contains(session.id) else { return }

        notifiedSessionIds.insert(session.id)

        let content = UNMutableNotificationContent()
        content.title = "Session Needs Attention"
        content.subtitle = session.displayName
        content.body = session.workStatus == .permission
            ? "Waiting for permission approval"
            : "Waiting for your input"
        content.sound = configuredSound
        content.categoryIdentifier = "SESSION_ATTENTION"

        // Add session info for handling tap
        content.userInfo = [
            "sessionId": session.id,
            "projectPath": session.projectPath
        ]

        let request = UNNotificationRequest(
            identifier: "attention-\(session.id)",
            content: content,
            trigger: nil // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to schedule notification: \(error)")
            }
        }
    }

    func clearNotification(for sessionId: String) {
        notifiedSessionIds.remove(sessionId)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["attention-\(sessionId)"])
    }

    func resetNotificationState(for sessionId: String) {
        // Call this when a session is no longer needing attention
        // so we can notify again if it needs attention later
        notifiedSessionIds.remove(sessionId)
    }
}
