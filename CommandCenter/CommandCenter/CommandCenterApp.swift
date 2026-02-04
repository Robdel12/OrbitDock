//
//  CommandCenterApp.swift
//  OrbitDock
//
//  Created by Robert DeLuca on 1/30/26.
//

import SwiftUI
import UserNotifications

@main
struct OrbitDockApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
  private let database = DatabaseManager.shared
  @State private var codexManager = CodexDirectSessionManager()

  var body: some Scene {
    // Main window
    WindowGroup {
      ContentView()
        .environment(database)
        .environment(codexManager)
        .preferredColorScheme(.dark)
        .onAppear {
          // Share manager reference with AppDelegate for recovery
          AppDelegate.codexManager = codexManager
        }
    }
    .windowStyle(.automatic)
    .defaultSize(width: 1_000, height: 700)

    // Settings window (⌘,)
    Settings {
      SettingsView()
        .preferredColorScheme(.dark)
    }

    // Menu bar
    MenuBarExtra {
      MenuBarView()
        .environment(database)
        .environment(codexManager)
    } label: {
      Image(systemName: "terminal.fill")
        .symbolRenderingMode(.monochrome)
    }
    .menuBarExtraStyle(.window)
  }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

  /// Shared Codex direct session manager for recovery
  static var codexManager: CodexDirectSessionManager?

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Set up notification delegate
    UNUserNotificationCenter.current().delegate = self

    // Initialize notification manager (triggers authorization request)
    _ = NotificationManager.shared

    // Define notification actions
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

    UNUserNotificationCenter.current().setNotificationCategories([category])

    CodexRolloutWatcher.shared.start()

    // Fetch latest model pricing in background
    ModelPricingService.shared.fetchPrices()

    // Recover active Codex direct sessions in background
    Task {
      if let manager = AppDelegate.codexManager {
        await manager.recoverActiveSessions()
      }
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    CodexRolloutWatcher.shared.stop()
    AppDelegate.codexManager?.disconnect()
  }

  func applicationWillResignActive(_ notification: Notification) {
    // Clean up expired cache entries when app goes to background
    TranscriptParser.cleanupCache()
  }

  /// Handle notification when app is in foreground
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    // Show notification even when app is in foreground
    completionHandler([.banner, .sound])
  }

  /// Handle notification tap
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let userInfo = response.notification.request.content.userInfo

    if let sessionId = userInfo["sessionId"] as? String {
      // Post notification to select this session
      NotificationCenter.default.post(
        name: .selectSession,
        object: nil,
        userInfo: ["sessionId": sessionId]
      )
    }

    // Bring app to foreground
    NSApp.activate(ignoringOtherApps: true)

    completionHandler()
  }
}

// MARK: - Notification Names

extension Notification.Name {
  static let selectSession = Notification.Name("selectSession")
  static let navigateToQuest = Notification.Name("navigateToQuest")
}
