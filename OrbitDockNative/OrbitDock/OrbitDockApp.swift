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
  @State private var appRuntime: OrbitDockAppRuntime
  @State private var rootShellStore: RootShellStore
  @State private var rootShellRuntime: RootShellRuntime
  private let modelPricingService: ModelPricingService

  init() {
    let appRuntime = OrbitDockAppRuntime(
      dependencies: OrbitDockAppRuntimeDependencies.live()
    )
    let rootShellStore = RootShellStore()
    let rootShellRuntime = RootShellRuntime(
      runtimeRegistry: appRuntime.runtimeRegistry,
      rootShellStore: rootShellStore
    )
    let modelPricingService = ModelPricingService.live()
    _appRuntime = State(initialValue: appRuntime)
    _rootShellStore = State(initialValue: rootShellStore)
    _rootShellRuntime = State(initialValue: rootShellRuntime)
    self.modelPricingService = modelPricingService
  #if os(macOS)
    appDelegate.configure(appRuntime: appRuntime, modelPricingService: modelPricingService)
  #endif
  }

  private var mainRootView: some View {
    OrbitDockWindowRoot(
      appRuntime: appRuntime,
      rootShellStore: rootShellStore,
      rootShellRuntime: rootShellRuntime
    )
      .environment(\.modelPricingService, modelPricingService)
      .task {
        rootShellRuntime.start()
        await appRuntime.startIfNeeded()
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
          #if os(macOS)
            .environment(\.serverManager, appRuntime.serverManager)
          #endif
          .environment(appRuntime.runtimeRegistry.activeSessionStore)
          .environment(\.modelPricingService, modelPricingService)
          .environment(appRuntime.runtimeRegistry)
          .environment(appRuntime.notificationManager)
          .preferredColorScheme(.dark)
      }

      // Menu bar
      MenuBarExtra {
        MenuBarView()
          .environment(\.modelPricingService, modelPricingService)
          .environment(appRuntime.runtimeRegistry)
          .environment(appRuntime.usageServiceRegistry)
          .environment(rootShellStore)
          .environment(\.colorScheme, .dark)
          .preferredColorScheme(.dark)
          .task {
            rootShellRuntime.start()
          }
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
    private var appRuntime: OrbitDockAppRuntime?
    private var modelPricingService: ModelPricingService?

    func configure(appRuntime: OrbitDockAppRuntime, modelPricingService: ModelPricingService) {
      self.appRuntime = appRuntime
      self.modelPricingService = modelPricingService
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
      // Disable macOS Ventura+ row-height estimation so our ConversationHeightEngine
      // has sole authority over heightOfRow: values.
      UserDefaults.standard.set(false, forKey: "NSTableViewCanEstimateRowHeights")

      NSApp.appearance = NSAppearance(named: .darkAqua)
      guard !AppRuntimeMode.isRunningTestsProcess else { return }

      AppFileLogger.shared.start()

      // Set up notification delegate
      // Ensure app-level notification ownership is initialized before we register categories.
      appRuntime?.notificationManager.configureAppSessionNotifications(delegate: self)

      // Fetch latest model pricing in background
      modelPricingService?.fetchPrices()

      let memoryPressureSource = DispatchSource.makeMemoryPressureSource(
        eventMask: [.warning, .critical],
        queue: .main
      )
      memoryPressureSource.setEventHandler { [weak self] in
        self?.appRuntime?.runtimeRegistry.handleMemoryPressure()
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
        appRuntime?.runtimeRegistry.stopAllRuntimes()
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
        let endpointId: UUID? = {
          if let raw = userInfo["endpointId"] as? UUID {
            return raw
          }
          if let raw = userInfo["endpointId"] as? String {
            return UUID(uuidString: raw)
          }
          return nil
        }()
        appRuntime?.externalNavigationCenter.submitSessionSelection(
          sessionId: sessionId,
          endpointId: endpointId
        )
      }

      // Bring app to foreground
      NSApp.activate(ignoringOtherApps: true)

      completionHandler()
    }
  }
#endif
