//
//  NotificationManager.swift
//  OrbitDock
//

import Foundation
import UserNotifications

struct NotificationPreferences {
  let stringForKey: (String) -> String?
  let objectForKey: (String) -> Any?
  let boolForKey: (String) -> Bool

  static func live(defaults: UserDefaults = .standard) -> NotificationPreferences {
    NotificationPreferences(
      stringForKey: { defaults.string(forKey: $0) },
      objectForKey: { defaults.object(forKey: $0) },
      boolForKey: { defaults.bool(forKey: $0) }
    )
  }
}

struct NotificationCenterClient {
  let requestAuthorization: (@escaping (Bool, Error?) -> Void) -> Void
  let setDelegate: (UNUserNotificationCenterDelegate?) -> Void
  let setNotificationCategories: (Set<UNNotificationCategory>) -> Void
  let addRequest: (UNNotificationRequest, @escaping (Error?) -> Void) -> Void
  let removeDeliveredNotifications: ([String]) -> Void

  static func live(center: UNUserNotificationCenter = .current()) -> NotificationCenterClient {
    NotificationCenterClient(
      requestAuthorization: { completion in
        center.requestAuthorization(options: [.alert, .sound, .badge], completionHandler: completion)
      },
      setDelegate: { delegate in
        center.delegate = delegate
      },
      setNotificationCategories: { categories in
        center.setNotificationCategories(categories)
      },
      addRequest: { request, completion in
        center.add(request, withCompletionHandler: completion)
      },
      removeDeliveredNotifications: { identifiers in
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
      }
    )
  }
}

@Observable
class NotificationManager {
  private var notifiedSessionIds: Set<String> = []
  private var workingSessionIds: Set<String> = [] // Track sessions that are currently working
  private var isAuthorized = false
  private let notificationCenter: NotificationCenterClient
  private let preferences: NotificationPreferences

  init(
    isAuthorized: Bool = false,
    requestsAuthorizationOnInit: Bool = true,
    notificationCenter: NotificationCenterClient = .live(),
    preferences: NotificationPreferences = .live()
  ) {
    self.isAuthorized = isAuthorized
    self.notificationCenter = notificationCenter
    self.preferences = preferences
    guard requestsAuthorizationOnInit else { return }
    guard !AppRuntimeMode.isRunningTestsProcess else { return }
    requestAuthorization()
  }

  func configureAppSessionNotifications(delegate: UNUserNotificationCenterDelegate) {
    notificationCenter.setDelegate(delegate)

    let viewAction = UNNotificationAction(
      identifier: "VIEW_SESSION",
      title: "View Session",
      options: [.foreground]
    )

    let category = UNNotificationCategory(
      identifier: "SESSION_ATTENTION",
      actions: [viewAction],
      intentIdentifiers: [],
      options: []
    )

    notificationCenter.setNotificationCategories([category])
  }

  func requestAuthorization() {
    guard !AppRuntimeMode.isRunningTestsProcess else { return }
    notificationCenter.requestAuthorization { granted, error in
      DispatchQueue.main.async {
        self.isAuthorized = granted
        if let error {
          print("Notification authorization error: \(error)")
        }
      }
    }
  }

  /// Get the configured notification sound from user preferences
  private var configuredSound: UNNotificationSound? {
    let soundName = preferences.stringForKey("notificationSound") ?? "default"

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
    if preferences.objectForKey("notificationsEnabled") == nil {
      return true
    }
    return preferences.boolForKey("notificationsEnabled")
  }

  /// Check if "notify when work complete" is enabled
  private var notifyOnWorkComplete: Bool {
    // Default to true if not set
    if preferences.objectForKey("notifyOnWorkComplete") == nil {
      return true
    }
    return preferences.boolForKey("notifyOnWorkComplete")
  }

  func notifyNeedsAttention(session: Session) {
    let scopedID = session.scopedID

    guard isAuthorized else { return }
    guard notificationsEnabled else { return }
    guard session.showsInMissionControl else { return }
    guard !notifiedSessionIds.contains(scopedID) else { return }

    notifiedSessionIds.insert(scopedID)

    let content = UNMutableNotificationContent()
    content.title = "Session Needs Attention"
    content.subtitle = session.displayName
    content.body = Self.attentionMessage(for: session)
    content.sound = configuredSound
    content.categoryIdentifier = "SESSION_ATTENTION"

    // Add session info for handling tap
    content.userInfo = [
      "sessionId": scopedID,
      "projectPath": session.projectPath,
    ]

    let request = UNNotificationRequest(
      identifier: "attention-\(scopedID)",
      content: content,
      trigger: nil // Deliver immediately
    )

    notificationCenter.addRequest(request) { error in
      if let error {
        print("Failed to schedule notification: \(error)")
      }
    }
  }

  func clearNotification(for sessionId: String) {
    notifiedSessionIds.remove(sessionId)
    notificationCenter.removeDeliveredNotifications(["attention-\(sessionId)"])
  }

  func resetNotificationState(for sessionId: String) {
    // Call this when a session is no longer needing attention
    // so we can notify again if it needs attention later
    notifiedSessionIds.remove(sessionId)
  }

  /// Track session work status and notify when work completes
  func updateSessionWorkStatus(session: Session) {
    let scopedID = session.scopedID
    let wasWorking = workingSessionIds.contains(scopedID)
    let isWorking = Self.shouldTrackAsWorking(session)

    if isWorking {
      workingSessionIds.insert(scopedID)
    } else if wasWorking, session.showsInMissionControl {
      workingSessionIds.remove(scopedID)
      notifyWorkComplete(session: session)
    } else if !session.showsInMissionControl {
      workingSessionIds.remove(scopedID)
    }
  }

  private func notifyWorkComplete(session: Session) {
    guard isAuthorized else { return }
    guard notificationsEnabled else { return }
    guard notifyOnWorkComplete else { return }

    let content = UNMutableNotificationContent()
    content.title = "\(session.provider.displayName) Finished"
    content.subtitle = session.displayName
    content.body = Self.completionMessage(for: session)
    content.sound = configuredSound
    content.categoryIdentifier = "SESSION_ATTENTION"

    content.userInfo = [
      "sessionId": session.scopedID,
      "projectPath": session.projectPath,
    ]

    let request = UNNotificationRequest(
      identifier: "complete-\(session.scopedID)-\(Date().timeIntervalSince1970)",
      content: content,
      trigger: nil
    )

    notificationCenter.addRequest(request) { error in
      if let error {
        print("Failed to schedule notification: \(error)")
      }
    }
  }

  static func attentionMessage(for session: Session) -> String {
    switch SessionDisplayStatus.from(session) {
      case .permission:
        return "Waiting for permission approval"
      case .question:
        return "Waiting for your answer"
      case .reply, .working, .ended:
        return "Waiting for your input"
    }
  }

  static func completionMessage(for session: Session) -> String {
    switch SessionDisplayStatus.from(session) {
      case .permission:
        return "Needs permission to continue"
      case .question:
        return "Asked a question"
      case .reply, .working, .ended:
        return "Ready for your next prompt"
    }
  }

  static func shouldTrackAsWorking(_ session: Session) -> Bool {
    session.showsInMissionControl && SessionDisplayStatus.from(session) == .working
  }
}
