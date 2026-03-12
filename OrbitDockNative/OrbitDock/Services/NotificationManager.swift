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

  @MainActor
  static func live(defaults: UserDefaults = .standard) -> NotificationPreferences {
    NotificationPreferences(
      stringForKey: { defaults.string(forKey: $0) },
      objectForKey: { defaults.object(forKey: $0) },
      boolForKey: { defaults.bool(forKey: $0) }
    )
  }
}

struct NotificationCenterClient {
  let requestAuthorization: (@Sendable @escaping (Bool, Error?) -> Void) -> Void
  let setDelegate: (UNUserNotificationCenterDelegate?) -> Void
  let setNotificationCategories: (Set<UNNotificationCategory>) -> Void
  let addRequest: (UNNotificationRequest, @Sendable @escaping (Error?) -> Void) -> Void
  let removeDeliveredNotifications: ([String]) -> Void

  @MainActor
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
@MainActor
class NotificationManager {
  private var notifiedSessionIds: Set<String> = []
  private var workingSessionIds: Set<String> = [] // Track sessions that are currently working
  private var isAuthorized = false
  private let shouldRequestAuthorizationOnStart: Bool
  private var hasStarted = false
  private let notificationCenter: NotificationCenterClient
  private let preferences: NotificationPreferences
  private let isRunningTestsProcess: Bool

  init(
    isAuthorized: Bool = false,
    shouldRequestAuthorizationOnStart: Bool = true,
    notificationCenter: NotificationCenterClient,
    preferences: NotificationPreferences,
    isRunningTestsProcess: Bool
  ) {
    self.isAuthorized = isAuthorized
    self.shouldRequestAuthorizationOnStart = shouldRequestAuthorizationOnStart
    self.notificationCenter = notificationCenter
    self.preferences = preferences
    self.isRunningTestsProcess = isRunningTestsProcess
  }

  convenience init(
    isAuthorized: Bool = false,
    shouldRequestAuthorizationOnStart: Bool = true
  ) {
    self.init(
      isAuthorized: isAuthorized,
      shouldRequestAuthorizationOnStart: shouldRequestAuthorizationOnStart,
      notificationCenter: .live(),
      preferences: .live(),
      isRunningTestsProcess: AppRuntimeMode.isRunningTestsProcess
    )
  }

  convenience init(
    isAuthorized: Bool = false,
    shouldRequestAuthorizationOnStart: Bool = true,
    notificationCenter: NotificationCenterClient,
    preferences: NotificationPreferences
  ) {
    self.init(
      isAuthorized: isAuthorized,
      shouldRequestAuthorizationOnStart: shouldRequestAuthorizationOnStart,
      notificationCenter: notificationCenter,
      preferences: preferences,
      isRunningTestsProcess: AppRuntimeMode.isRunningTestsProcess
    )
  }

  @MainActor
  static func live(
    isAuthorized: Bool = false,
    shouldRequestAuthorizationOnStart: Bool = true
  ) -> NotificationManager {
    NotificationManager(
      isAuthorized: isAuthorized,
      shouldRequestAuthorizationOnStart: shouldRequestAuthorizationOnStart,
      notificationCenter: .live(),
      preferences: .live()
    )
  }

  func startIfNeeded() {
    guard !hasStarted else { return }
    hasStarted = true
    guard shouldRequestAuthorizationOnStart else { return }
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
    guard !isRunningTestsProcess else { return }
    notificationCenter.requestAuthorization { granted, error in
      Task { @MainActor in
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

  func notifyNeedsAttention(session: RootSessionNode) {
    let scopedID = session.scopedID

    guard isAuthorized else { return }
    guard notificationsEnabled else { return }
    guard session.showsInMissionControl else { return }
    guard session.allowsUserNotifications else {
      resetNotificationState(for: scopedID)
      return
    }
    guard !notifiedSessionIds.contains(scopedID) else { return }

    notifiedSessionIds.insert(scopedID)

    let content = UNMutableNotificationContent()
    content.title = "Session Needs Attention"
    content.subtitle = session.displayName
    content.body = Self.attentionMessage(for: session)
    content.sound = configuredSound
    content.categoryIdentifier = "SESSION_ATTENTION"
    content.userInfo = [
      "sessionId": scopedID,
      "projectPath": session.projectPath,
    ]

    let request = UNNotificationRequest(
      identifier: "attention-\(scopedID)",
      content: content,
      trigger: nil
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

  func sendTestNotification(soundID: String) {
    guard notificationsEnabled else { return }

    let content = UNMutableNotificationContent()
    content.title = "Test Notification"
    content.subtitle = "OrbitDock"
    content.body = "This is a test notification. Your settings are working!"
    content.categoryIdentifier = "SESSION_ATTENTION"
    content.sound = sound(for: soundID)

    let request = UNNotificationRequest(
      identifier: "test-notification-\(UUID().uuidString)",
      content: content,
      trigger: nil
    )

    notificationCenter.addRequest(request) { error in
      if let error {
        print("Failed to schedule notification: \(error)")
      }
    }
  }

  func resetNotificationState(for sessionId: String) {
    // Call this when a session is no longer needing attention
    // so we can notify again if it needs attention later
    notifiedSessionIds.remove(sessionId)
  }

  /// Track session work status and notify when work completes
  func updateSessionWorkStatus(session: RootSessionNode) {
    let scopedID = session.scopedID
    let wasWorking = workingSessionIds.contains(scopedID)
    let shouldTrackAsWorking = Self.shouldTrackAsWorking(session)

    if !session.allowsUserNotifications {
      workingSessionIds.remove(scopedID)
      resetNotificationState(for: scopedID)
      return
    }

    if wasWorking && !shouldTrackAsWorking {
      if notifyOnWorkComplete {
        notifyWorkComplete(session: session)
      }
      workingSessionIds.remove(scopedID)
      return
    }

    if shouldTrackAsWorking {
      workingSessionIds.insert(scopedID)
    } else {
      workingSessionIds.remove(scopedID)
    }
  }

  private func notifyWorkComplete(session: RootSessionNode) {
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

  private func sound(for soundID: String) -> UNNotificationSound? {
    switch soundID {
      case "none":
        return nil
      case "default":
        return .default
      default:
        return UNNotificationSound(named: UNNotificationSoundName(rawValue: soundID))
    }
  }

  static func attentionMessage(for session: RootSessionNode) -> String {
    switch SessionDisplayStatus.from(session) {
      case .permission:
        if let pendingToolName = session.pendingToolName, !pendingToolName.isEmpty {
          return "Needs approval to run \(pendingToolName)."
        }
        return "Needs approval to continue."
      case .question:
        return "Has a question for you."
      case .reply:
        return "Is waiting for your reply."
      case .working:
        return "Is actively working."
      case .ended:
        return "Has ended."
    }
  }

  static func completionMessage(for session: RootSessionNode) -> String {
    "Finished work in \(session.displayName)."
  }

  static func shouldTrackAsWorking(_ session: RootSessionNode) -> Bool {
    session.showsInMissionControl
      && session.allowsUserNotifications
      && session.displayStatus == .working
  }
}
