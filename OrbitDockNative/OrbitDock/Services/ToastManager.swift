import SwiftUI

@MainActor
@Observable
final class ToastManager {
  var toasts: [SessionToast] = []

  private var notifiedSessionIds: Set<String> = []

  var currentSessionId: String?

  private let dismissDuration: TimeInterval = 5.0
  private var dismissTasks: [UUID: Task<Void, Never>] = [:]
  private var lastAttentionHapticAt = Date.distantPast

  init() {}

  func dismiss(_ toast: SessionToast) {
    dismissTasks[toast.id]?.cancel()
    dismissTasks.removeValue(forKey: toast.id)
    toasts.removeAll { $0.id == toast.id }
  }

  func clearNotification(for sessionId: String) {
    notifiedSessionIds.remove(sessionId)
  }

  func showToast(for session: RootSessionNode) {
    let scopedID = session.scopedID

    guard session.showsInMissionControl else { return }
    guard session.allowsUserNotifications else {
      clearNotification(for: scopedID)
      return
    }
    guard scopedID != currentSessionId else { return }
    guard !notifiedSessionIds.contains(scopedID) else { return }

    let status = session.displayStatus
    guard status == .permission || status == .question else { return }

    let toast = SessionToast(
      sessionId: scopedID,
      sessionName: session.title,
      status: session.displayStatus,
      detail: session.pendingToolName
    )

    notifiedSessionIds.insert(scopedID)
    toasts.append(toast)
    if Date().timeIntervalSince(lastAttentionHapticAt) > 0.75 {
      Platform.services.playHaptic(.warning)
      lastAttentionHapticAt = Date()
    }

    let task = Task {
      try? await Task.sleep(for: .seconds(dismissDuration))
      dismiss(toast)
    }
    dismissTasks[toast.id] = task
  }

  func applySessionTransition(current session: RootSessionNode, previous: RootSessionNode?) {
    let scopedID = session.scopedID
    let currentStatus = session.displayStatus
    let previousStatus = previous?.displayStatus

    if !session.allowsUserNotifications {
      clearNotification(for: scopedID)
      return
    }

    if currentStatus == .permission || currentStatus == .question,
       previousStatus != currentStatus
    {
      showToast(for: session)
    }

    if currentStatus != .permission, currentStatus != .question {
      clearNotification(for: scopedID)
    }
  }

  func removeSession(_ sessionId: String) {
    clearNotification(for: sessionId)
    let matchingToasts = toasts.filter { $0.sessionId == sessionId }
    for toast in matchingToasts {
      dismiss(toast)
    }
  }
}
