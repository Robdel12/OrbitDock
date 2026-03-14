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
  private let modelPricingService: ModelPricingService

  init() {
    let appRuntime = OrbitDockAppRuntime()
    let modelPricingService = ModelPricingService.live()
    _appRuntime = State(initialValue: appRuntime)
    self.modelPricingService = modelPricingService
    #if os(macOS)
      appDelegate.configure(appRuntime: appRuntime, modelPricingService: modelPricingService)
    #endif
  }

  private var mainRootView: some View {
    OrbitDockWindowRoot(appRuntime: appRuntime)
      .environment(\.modelPricingService, modelPricingService)
      .task {
        await appRuntime.startIfNeeded()
      }
  }

  var body: some Scene {
    #if os(macOS)
      WindowGroup {
        mainRootView
          .frame(minWidth: 1_000, maxWidth: .infinity, minHeight: 700, maxHeight: .infinity)
      }
      .windowStyle(.hiddenTitleBar)
      .defaultSize(width: 1_000, height: 700)
      .commands {
        OrbitDockWindowCommands()
      }

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

      MenuBarExtra {
        MenuBarView()
          .environment(\.modelPricingService, modelPricingService)
          .environment(appRuntime.runtimeRegistry)
          .environment(appRuntime.usageServiceRegistry)
          .environment(appRuntime.runtimeRegistry.appStoreForMenuBar)
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
    private var appRuntime: OrbitDockAppRuntime?
    private var modelPricingService: ModelPricingService?

    func configure(appRuntime: OrbitDockAppRuntime, modelPricingService: ModelPricingService) {
      self.appRuntime = appRuntime
      self.modelPricingService = modelPricingService
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
      UserDefaults.standard.set(false, forKey: "NSTableViewCanEstimateRowHeights")
      NSApp.appearance = NSAppearance(named: .darkAqua)
      guard !AppRuntimeMode.isRunningTestsProcess else { return }

      AppFileLogger.shared.start()
      appRuntime?.notificationManager.configureAppSessionNotifications(delegate: self)
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

    func userNotificationCenter(
      _ center: UNUserNotificationCenter,
      willPresent notification: UNNotification,
      withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
      completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
      _ center: UNUserNotificationCenter,
      didReceive response: UNNotificationResponse,
      withCompletionHandler completionHandler: @escaping () -> Void
    ) {
      let userInfo = response.notification.request.content.userInfo
      if let sessionId = userInfo["sessionId"] as? String {
        let endpointId = (userInfo["endpointId"] as? String).flatMap(UUID.init(uuidString:))
        appRuntime?.externalNavigationCenter.submitSessionSelection(
          sessionId: sessionId,
          endpointId: endpointId
        )
      }
      NSApp.activate(ignoringOtherApps: true)
      completionHandler()
    }
  }
#endif
