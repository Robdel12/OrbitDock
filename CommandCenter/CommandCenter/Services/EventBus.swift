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
  let transcriptUpdated = PassthroughSubject<String, Never>() // transcript path

  // Debounce state
  private var pendingSessionUpdate: DispatchWorkItem?
  private var pendingTranscriptUpdates: [String: DispatchWorkItem] = [:]

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

    // Transcript changed (new messages)
    CFNotificationCenterAddObserver(
      center,
      Unmanaged.passUnretained(self).toOpaque(),
      { _, observer, _, _, _ in
        guard let observer else { return }
        let eventBus = Unmanaged<EventBus>.fromOpaque(observer).takeUnretainedValue()
        eventBus.handleTranscriptNotification()
      },
      "com.orbitdock.transcript.updated" as CFString,
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

  private func handleTranscriptNotification() {
    // For transcript, we don't know which one changed from Darwin notification
    // So we trigger a general refresh - file watchers handle specific paths
    DispatchQueue.main.async { [weak self] in
      self?.sessionUpdated.send(nil)
    }
  }

  // MARK: - File System Events

  /// Called when a specific transcript file changes
  func notifyTranscriptChanged(path: String) {
    // Debounce per-path - 150ms for better responsiveness while still batching rapid events
    // (Reduced from 300ms - fast enough to feel responsive, slow enough to batch tool spam)
    pendingTranscriptUpdates[path]?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      DispatchQueue.main.async {
        self?.transcriptUpdated.send(path)
      }
      self?.pendingTranscriptUpdates.removeValue(forKey: path)
    }
    pendingTranscriptUpdates[path] = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
  }

  /// Called when database file changes
  func notifyDatabaseChanged() {
    handleSessionNotification() // Reuse debouncing logic
  }
}
