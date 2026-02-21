//
//  OrbitDockApp.swift
//  OrbitDock
//
//  Created by Robert DeLuca on 1/30/26.
//

import SwiftUI
import UserNotifications
#if os(macOS)
  import AppKit
#elseif os(iOS)
  import UIKit
#endif

@main
struct OrbitDockApp: App {
  #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
  #endif
  @State private var serverAppState = ServerAppState()
  @State private var attentionService = AttentionService()
  private let runtimeMode = AppRuntimeMode.current

  private var mainRootView: some View {
    ContentView()
      .environment(serverAppState)
      .environment(attentionService)
      .preferredColorScheme(.dark)
    #if os(iOS)
      .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
        serverAppState.handleMemoryPressure()
        MarkdownAttributedStringRenderer.clearCache()
        NativeSyntaxHighlighter.clearCache()
      }
    #endif
      .task {
        guard runtimeMode.shouldConnectServer else { return }
        // Wire up server state after connection is established
        serverAppState.setup()
        if runtimeMode.shouldStartMcpBridge {
          // Start MCP Bridge for external tool access
          MCPBridge.shared.start(serverAppState: serverAppState)
        }

        // Check server install state before connecting
        await ServerManager.shared.refreshState()

        let state = ServerManager.shared.installState
        if state == .running || state == .installed || state == .remote {
          ServerConnection.shared.connect(to: ServerEndpointSettings.effectiveURL)
        }
        // .notConfigured → setup view handles connection after install
      }
  }

  var body: some Scene {
    #if os(macOS)
      // Main window
      WindowGroup {
        mainRootView
      }
      .windowStyle(.automatic)
      .defaultSize(width: 1_000, height: 700)

      // Settings window (⌘,)
      Settings {
        SettingsView()
          .environment(serverAppState)
          .environment(attentionService)
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
    #else
      WindowGroup {
        mainRootView
      }
    #endif
  }
}

// MARK: - App Delegate

#if os(macOS)
  class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    /// Shared server app state for MCP bridge
    static var serverAppState: ServerAppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
      // Disable macOS Ventura+ row-height estimation so our ConversationHeightEngine
      // has sole authority over heightOfRow: values.
      UserDefaults.standard.set(false, forKey: "NSTableViewCanEstimateRowHeights")

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
    }

    func applicationWillTerminate(_ notification: Notification) {
      Task { @MainActor in
        MCPBridge.shared.stop()
        ServerConnection.shared.disconnect()
      }
    }

    func applicationWillResignActive(_ notification: Notification) {}

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
#endif

// MARK: - Notification Names

extension Notification.Name {
  static let selectSession = Notification.Name("selectSession")
}
