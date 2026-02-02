//
//  ToastManager.swift
//  OrbitDock
//
//  Manages in-app toast notifications for session status changes
//

import SwiftUI
import Combine

@MainActor
class ToastManager: ObservableObject {
  static let shared = ToastManager()

  @Published var toasts: [SessionToast] = []

  /// Sessions we've already shown a toast for (to avoid duplicates)
  private var notifiedSessionIds: Set<String> = []

  /// The session currently being viewed (don't show toasts for this one)
  var currentSessionId: String?

  /// Auto-dismiss duration in seconds
  private let dismissDuration: TimeInterval = 5.0

  private var dismissTasks: [UUID: Task<Void, Never>] = [:]

  private init() {}

  /// Show a toast for a session that needs attention
  func showToast(for session: Session) {
    // Don't show if viewing this session
    guard session.id != currentSessionId else { return }

    // Don't show duplicate toasts
    guard !notifiedSessionIds.contains(session.id) else { return }

    let status = SessionDisplayStatus.from(session)

    // Only show for attention-needing states
    guard status == .permission || status == .question else { return }

    let toast = SessionToast(
      sessionId: session.id,
      sessionName: session.displayName,
      status: status,
      detail: session.pendingToolName
    )

    notifiedSessionIds.insert(session.id)
    toasts.append(toast)

    // Schedule auto-dismiss
    let task = Task {
      try? await Task.sleep(for: .seconds(dismissDuration))
      dismiss(toast)
    }
    dismissTasks[toast.id] = task
  }

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

  /// Check sessions for status changes and show toasts as needed
  func checkForAttentionChanges(sessions: [Session], previousSessions: [Session]) {
    let previousStates = Dictionary(uniqueKeysWithValues: previousSessions.map { ($0.id, SessionDisplayStatus.from($0)) })

    for session in sessions {
      let currentStatus = SessionDisplayStatus.from(session)
      let previousStatus = previousStates[session.id]

      // Session transitioned TO needing attention
      if (currentStatus == .permission || currentStatus == .question) &&
         previousStatus != currentStatus {
        showToast(for: session)
      }

      // Session no longer needs attention - clear tracking
      if currentStatus != .permission && currentStatus != .question {
        clearNotification(for: session.id)
      }
    }
  }
}
