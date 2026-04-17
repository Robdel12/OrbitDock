import Foundation
import UserNotifications

// MARK: - DI Boundaries

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

// MARK: - Coordinator

@Observable
@MainActor
final class NotificationCoordinator {
  private let notificationCenter: NotificationCenterClient
  private let preferences: NotificationPreferences
  private let isRunningTestsProcess: Bool

  private(set) var toasts: [SessionToast] = []
  @ObservationIgnored private var previousSessionIndex: [String: RootSessionNode] = [:]
  @ObservationIgnored private var notifiedSessionIds: Set<String> = []
  @ObservationIgnored private var dismissTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var lastAttentionHapticAt = Date.distantPast

  var isAuthorized = false
  @ObservationIgnored private var hasStarted = false

  // External inputs — set by the view layer
  var viewedSessionScopedID: String?
  var appIsActive: Bool = true

  // MARK: - Init

  init(
    notificationCenter: NotificationCenterClient,
    preferences: NotificationPreferences,
    isRunningTestsProcess: Bool = false
  ) {
    self.notificationCenter = notificationCenter
    self.preferences = preferences
    self.isRunningTestsProcess = isRunningTestsProcess
  }

  convenience init() {
    self.init(
      notificationCenter: .live(),
      preferences: .live(),
      isRunningTestsProcess: AppRuntimeMode.isRunningTestsProcess
    )
  }

  // MARK: - Lifecycle

  func startIfNeeded() {
    guard !hasStarted else { return }
    hasStarted = true
    requestAuthorization()
  }

  func configureCategories(delegate: UNUserNotificationCenterDelegate) {
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
        _ = error
      }
    }
  }

  // MARK: - Session State Processing

  /// Seed the baseline without triggering notifications.
  /// Call once on app launch with the initial session list to avoid
  /// a burst of toasts for sessions that were already needing attention.
  func seedBaseline(_ sessions: [RootSessionNode]) {
    previousSessionIndex = Dictionary(
      sessions.map { ($0.scopedID, $0) },
      uniquingKeysWith: { _, last in last }
    )
  }

  func processSessionUpdate(_ sessions: [RootSessionNode]) {
    let currentIndex = Dictionary(
      sessions.map { ($0.scopedID, $0) },
      uniquingKeysWith: { _, last in last }
    )

    let transitions = SessionTransitionDiff.transitions(
      previous: previousSessionIndex,
      current: currentIndex
    )

    previousSessionIndex = currentIndex

    for transition in transitions {
      routeTransition(transition)
    }
  }

  // MARK: - Toast Management

  func dismiss(_ toast: SessionToast) {
    dismissTasks[toast.id]?.cancel()
    dismissTasks.removeValue(forKey: toast.id)
    toasts.removeAll { $0.id == toast.id }
  }

  // MARK: - Test Notification

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
      _ = error
    }
  }

  // MARK: - Routing

  private func routeTransition(_ transition: SessionTransition) {
    switch transition {
      case let .needsAttention(scopedID, status, title, detail):
        guard notificationsEnabled else { return }
        guard scopedID != viewedSessionScopedID else { return }
        guard !notifiedSessionIds.contains(scopedID) else { return }

        notifiedSessionIds.insert(scopedID)

        if appIsActive {
          if showInAppToasts {
            appendToast(scopedID: scopedID, title: title, status: status, detail: detail)
          }
        } else {
          sendAttentionNotification(scopedID: scopedID, title: title, status: status, detail: detail)
        }

      case let .workComplete(scopedID, title, provider):
        guard notificationsEnabled else { return }
        guard notifyOnWorkComplete else { return }
        guard scopedID != viewedSessionScopedID else { return }

        if !appIsActive {
          sendWorkCompleteNotification(scopedID: scopedID, title: title, provider: provider)
        }

      case let .attentionCleared(scopedID):
        notifiedSessionIds.remove(scopedID)
        clearOSNotification(for: scopedID)
        clearToast(for: scopedID)
    }
  }

  // MARK: - Toast

  private func appendToast(scopedID: String, title: String, status: SessionDisplayStatus, detail: String?) {
    let toast = SessionToast(
      sessionId: scopedID,
      sessionName: title,
      status: status,
      detail: detail
    )

    toasts.append(toast)

    if Date().timeIntervalSince(lastAttentionHapticAt) > 0.75 {
      Platform.services.playHaptic(.warning)
      lastAttentionHapticAt = Date()
    }

    let task = Task {
      try? await Task.sleep(for: .seconds(5))
      dismiss(toast)
    }
    dismissTasks[toast.id] = task
  }

  private func clearToast(for scopedID: String) {
    let matching = toasts.filter { $0.sessionId == scopedID }
    for toast in matching {
      dismiss(toast)
    }
  }

  // MARK: - OS Notifications

  private func sendAttentionNotification(
    scopedID: String,
    title: String,
    status: SessionDisplayStatus,
    detail: String?
  ) {
    guard isAuthorized else { return }

    let content = UNMutableNotificationContent()
    content.title = "Session Needs Attention"
    content.subtitle = title
    content.body = attentionMessage(status: status, detail: detail)
    content.sound = configuredSound
    content.categoryIdentifier = "SESSION_ATTENTION"
    content.userInfo = ["sessionId": scopedID]

    let request = UNNotificationRequest(
      identifier: "attention-\(scopedID)",
      content: content,
      trigger: nil
    )

    notificationCenter.addRequest(request) { error in
      _ = error
    }
  }

  private func sendWorkCompleteNotification(scopedID: String, title: String, provider: Provider) {
    guard isAuthorized else { return }

    let content = UNMutableNotificationContent()
    content.title = "\(provider.displayName) Finished"
    content.subtitle = title
    content.body = "Finished work in \(title)."
    content.sound = configuredSound
    content.categoryIdentifier = "SESSION_ATTENTION"
    content.userInfo = ["sessionId": scopedID]

    let request = UNNotificationRequest(
      identifier: "complete-\(scopedID)-\(Date().timeIntervalSince1970)",
      content: content,
      trigger: nil
    )

    notificationCenter.addRequest(request) { error in
      _ = error
    }
  }

  private func clearOSNotification(for scopedID: String) {
    notificationCenter.removeDeliveredNotifications(["attention-\(scopedID)"])
  }

  // MARK: - Preferences

  private var notificationsEnabled: Bool {
    if preferences.objectForKey("notificationsEnabled") == nil {
      return true
    }
    return preferences.boolForKey("notificationsEnabled")
  }

  private var notifyOnWorkComplete: Bool {
    if preferences.objectForKey("notifyOnWorkComplete") == nil {
      return true
    }
    return preferences.boolForKey("notifyOnWorkComplete")
  }

  private var showInAppToasts: Bool {
    if preferences.objectForKey("showInAppToasts") == nil {
      return true
    }
    return preferences.boolForKey("showInAppToasts")
  }

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

  private func sound(for soundID: String) -> UNNotificationSound? {
    switch soundID {
      case "none": nil
      case "default": .default
      default: UNNotificationSound(named: UNNotificationSoundName(rawValue: soundID))
    }
  }

  // MARK: - Message Formatting

  static func attentionMessage(for session: RootSessionNode) -> String {
    attentionBody(status: session.displayStatus, detail: session.pendingToolName)
  }

  static func completionMessage(for session: RootSessionNode) -> String {
    "Finished work in \(session.title)."
  }

  static func shouldTrackAsWorking(_ session: RootSessionNode) -> Bool {
    session.showsInMissionControl
      && session.allowsUserNotifications
      && session.displayStatus == .working
  }

  private func attentionMessage(status: SessionDisplayStatus, detail: String?) -> String {
    Self.attentionBody(status: status, detail: detail)
  }

  private static func attentionBody(status: SessionDisplayStatus, detail: String?) -> String {
    switch status {
      case .permission:
        if let toolName = detail, !toolName.isEmpty {
          return "Needs approval to run \(toolName)."
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
}
