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
    private var workingSessionIds: Set<String> = []  // Track sessions that are currently working
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

    /// Check if "notify when work complete" is enabled
    private var notifyOnWorkComplete: Bool {
        // Default to true if not set
        if UserDefaults.standard.object(forKey: "notifyOnWorkComplete") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "notifyOnWorkComplete")
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

    /// Track session work status and notify when work completes
    func updateSessionWorkStatus(session: Session) {
        let wasWorking = workingSessionIds.contains(session.id)
        let isWorking = session.isActive && session.workStatus == .working

        if isWorking {
            // Session started working
            workingSessionIds.insert(session.id)
        } else if wasWorking && !isWorking && session.isActive {
            // Session was working but now stopped (waiting/permission)
            workingSessionIds.remove(session.id)
            notifyWorkComplete(session: session)
        } else if !session.isActive {
            // Session ended, clean up
            workingSessionIds.remove(session.id)
        }
    }

    private func notifyWorkComplete(session: Session) {
        guard isAuthorized else { return }
        guard notificationsEnabled else { return }
        guard notifyOnWorkComplete else { return }

        let content = UNMutableNotificationContent()
        content.title = "Claude Finished"
        content.subtitle = session.displayName
        content.body = session.workStatus == .permission
            ? "Needs permission to continue"
            : "Ready for your next prompt"
        content.sound = configuredSound
        content.categoryIdentifier = "SESSION_ATTENTION"

        content.userInfo = [
            "sessionId": session.id,
            "projectPath": session.projectPath
        ]

        let request = UNNotificationRequest(
            identifier: "complete-\(session.id)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to schedule notification: \(error)")
            }
        }
    }
}
