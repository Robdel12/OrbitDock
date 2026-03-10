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
  import Dispatch
#elseif os(iOS)
  import UIKit
#endif

@main
struct OrbitDockApp: App {
  #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
  #endif
  @State private var runtimeRegistry: ServerRuntimeRegistry
  @State private var usageServiceRegistry: UsageServiceRegistry
  private let runtimeMode = AppRuntimeMode.current

  init() {
    let runtimeRegistry = ServerRuntimeRegistry.shared
    _runtimeRegistry = State(initialValue: runtimeRegistry)
    _usageServiceRegistry = State(initialValue: UsageServiceRegistry(runtimeRegistry: runtimeRegistry))
  }

  private var mainRootView: some View {
    OrbitDockWindowRoot(runtimeRegistry: runtimeRegistry, usageServiceRegistry: usageServiceRegistry)
      .task {
        guard runtimeMode.shouldConnectServer else { return }

        runtimeRegistry.configureFromSettings(startEnabled: false)

        // Check server install state before connecting
        await ServerManager.shared.refreshState()

        let state = ServerManager.shared.installState
        if state == .running || state == .installed || state == .remote {
          runtimeRegistry.startEnabledRuntimes()
        }
        if UsageServiceRegistry.shouldStartServices(
          shouldConnectServer: runtimeMode.shouldConnectServer,
          installState: state
        ) {
          usageServiceRegistry.start()
        } else {
          usageServiceRegistry.stop()
        }
        // .notConfigured → setup view handles connection after install
      }
  }

  var body: some Scene {
    #if os(macOS)
      // Main window
      WindowGroup {
        mainRootView
          .frame(minWidth: 1_000, maxWidth: .infinity, minHeight: 700, maxHeight: .infinity)
      }
      .windowStyle(.hiddenTitleBar)
      .defaultSize(width: 1_000, height: 700)
      .commands {
        OrbitDockWindowCommands()
      }

      // Settings window (⌘,)
      Settings {
        SettingsView()
          .environment(runtimeRegistry)
          .preferredColorScheme(.dark)
      }

      // Menu bar
      MenuBarExtra {
        MenuBarView()
          .environment(runtimeRegistry.activeSessionStore)
          .environment(runtimeRegistry)
          .environment(usageServiceRegistry)
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

struct OrbitDockWindowCommands: Commands {
  @FocusedValue(\.orbitDockRouter) private var router

  var body: some Commands {
    CommandGroup(after: .toolbar) {
      Button("Dashboard") {
        router?.goToDashboard()
      }
      .keyboardShortcut("0", modifiers: .command)
      .disabled(router == nil)

      Button("Library") {
        router?.goToLibrary()
      }
      .keyboardShortcut("1", modifiers: .command)
      .disabled(router == nil)

      Button("Quick Switch") {
        router?.openQuickSwitcher()
      }
      .keyboardShortcut("k", modifiers: .command)
      .disabled(router == nil)
    }
  }
}

// MARK: - App Delegate

#if os(macOS)
  class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    func applicationDidFinishLaunching(_ notification: Notification) {
      // Disable macOS Ventura+ row-height estimation so our ConversationHeightEngine
      // has sole authority over heightOfRow: values.
      UserDefaults.standard.set(false, forKey: "NSTableViewCanEstimateRowHeights")

      NSApp.appearance = NSAppearance(named: .darkAqua)
      guard !AppRuntimeMode.isRunningTestsProcess else { return }

      AppFileLogger.shared.start()

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

      let memoryPressureSource = DispatchSource.makeMemoryPressureSource(
        eventMask: [.warning, .critical],
        queue: .main
      )
      memoryPressureSource.setEventHandler {
        ServerRuntimeRegistry.shared.handleMemoryPressure()
        MarkdownSystemParser.clearCache()
        SyntaxHighlighter.clearCache()
      }
      memoryPressureSource.resume()
      self.memoryPressureSource = memoryPressureSource
    }

    func applicationWillTerminate(_ notification: Notification) {
      memoryPressureSource?.cancel()
      memoryPressureSource = nil

      Task { @MainActor in
        ServerRuntimeRegistry.shared.stopAllRuntimes()
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
  static let serverSessionsDidChange = Notification.Name("serverSessionsDidChange")
  static let serverPrimaryEndpointDidChange = Notification.Name("serverPrimaryEndpointDidChange")
  static let openPendingActionPanel = Notification.Name("openPendingActionPanel")
}
