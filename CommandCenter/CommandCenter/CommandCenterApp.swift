//
//  CommandCenterApp.swift
//  OrbitDock
//
//  Created by Robert DeLuca on 1/30/26.
//

import SwiftUI
import UserNotifications
import AppKit

@main
struct OrbitDockApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
  @State private var serverAppState = ServerAppState()
  @State private var attentionService = AttentionService()

  var body: some Scene {
    // Main window
    WindowGroup {
      ContentView()
        .environment(serverAppState)
        .environment(attentionService)
        .preferredColorScheme(.dark)
        .task {
          // Wire up server state after connection is established
          serverAppState.setup()
          // Start MCP Bridge for external tool access
          MCPBridge.shared.start(serverAppState: serverAppState)
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
        .environment(serverAppState)
        .environment(attentionService)
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
    } label: {
      Image(systemName: "terminal.fill")
        .symbolRenderingMode(.monochrome)
    }
    .menuBarExtraStyle(.window)
  }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

  /// Shared server app state for MCP bridge
  static var serverAppState: ServerAppState?

  func applicationDidFinishLaunching(_ notification: Notification) {
    AppFileLogger.shared.start()
    NSApp.appearance = NSAppearance(named: .darkAqua)

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

    // Fetch latest model pricing in background
    ModelPricingService.shared.fetchPrices()

    // Start the Rust server (limited retries, won't poll forever)
    Task { @MainActor in
      ServerManager.shared.start()

      // Connect WebSocket client once server is ready (warm-up + exponential backoff)
      let ready = await ServerManager.shared.waitForReady(maxAttempts: 10)
      if ready {
        ServerConnection.shared.connect()
      }
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    // Stop MCP Bridge and Rust server
    Task { @MainActor in
      MCPBridge.shared.stop()
      ServerConnection.shared.disconnect()
      ServerManager.shared.stop()
    }
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
}
