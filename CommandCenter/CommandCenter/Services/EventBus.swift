//
//  EventBus.swift
//  OrbitDock
//
//  Centralized event system for efficient updates.
//  Uses Darwin notifications from hooks + file system monitoring.
//

import Combine
import Foundation

/// Central event bus for coordinating updates across the app
final class EventBus {
  static let shared = EventBus()

  // Publishers for different event types
  let sessionUpdated = PassthroughSubject<String?, Never>() // session ID or nil for all

  // Debounce state
  private var pendingSessionUpdate: DispatchWorkItem?

  private init() {
    setupDarwinNotifications()
  }

  // MARK: - Darwin Notifications (from hooks)

  private func setupDarwinNotifications() {
    // Listen for session updates from hooks
    let center = CFNotificationCenterGetDarwinNotifyCenter()

    // Session data changed (database update)
    CFNotificationCenterAddObserver(
      center,
      Unmanaged.passUnretained(self).toOpaque(),
      { _, observer, _, _, _ in
        guard let observer else { return }
        let eventBus = Unmanaged<EventBus>.fromOpaque(observer).takeUnretainedValue()
        eventBus.handleSessionNotification()
      },
      "com.orbitdock.session.updated" as CFString,
      nil,
      .deliverImmediately
    )
  }

  private func handleSessionNotification() {
    // Debounce: wait 100ms for more updates before firing
    pendingSessionUpdate?.cancel()
    pendingSessionUpdate = DispatchWorkItem { [weak self] in
      DispatchQueue.main.async {
        self?.sessionUpdated.send(nil)
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: pendingSessionUpdate!)
  }

  /// Called when database file changes
  func notifyDatabaseChanged() {
    handleSessionNotification() // Reuse debouncing logic
  }
}
