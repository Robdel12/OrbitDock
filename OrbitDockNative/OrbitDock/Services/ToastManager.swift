//
//  ToastManager.swift
//  OrbitDock
//
//  Manages in-app toast notifications for session status changes
//

import Combine
import SwiftUI

@MainActor
class ToastManager: ObservableObject {
  @Published var toasts: [SessionToast] = []

  /// Sessions we've already shown a toast for (to avoid duplicates)
  private var notifiedSessionIds: Set<String> = []

  /// The session currently being viewed (don't show toasts for this one)
  var currentSessionId: String?

  /// Auto-dismiss duration in seconds
  private let dismissDuration: TimeInterval = 5.0

  private var dismissTasks: [UUID: Task<Void, Never>] = [:]
  private var lastAttentionHapticAt = Date.distantPast

  init() {}

  /// Dismiss a specific toast
  func dismiss(_ toast: SessionToast) {
    dismissTasks[toast.id]?.cancel()
    dismissTasks.removeValue(forKey: toast.id)
    toasts.removeAll { $0.id == toast.id }
  }

  /// Clear notification tracking for a session (call when session no longer needs attention)
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

    let status = SessionDisplayStatus.from(session)
    guard status == .permission || status == .question else { return }

    let toast = SessionToast(
      sessionId: scopedID,
      sessionName: session.displayName,
      status: status,
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

  func checkForAttentionChanges(
    sessions: [RootSessionNode],
    previousSessions: [RootSessionNode]
  ) {
    let previousStates = Dictionary(uniqueKeysWithValues: previousSessions
      .map { ($0.scopedID, SessionDisplayStatus.from($0)) })

    for session in sessions {
      let scopedID = session.scopedID
      let currentStatus = SessionDisplayStatus.from(session)
      let previousStatus = previousStates[scopedID]

      if !session.allowsUserNotifications {
        clearNotification(for: scopedID)
        continue
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
  }
}
