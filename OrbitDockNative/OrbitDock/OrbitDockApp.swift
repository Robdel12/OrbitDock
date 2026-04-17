import SwiftUI
import UserNotifications
#if os(macOS)
  import AppKit
#endif

@main
struct OrbitDockApp: App {
  #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
  #else
    @UIApplicationDelegateAdaptor(iOSAppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase
  #endif
  @State private var appRuntime: OrbitDockAppRuntime
  private let modelPricingService: ModelPricingService

  init() {
    let appRuntime = OrbitDockAppRuntime()
    let modelPricingService = ModelPricingService.live()
    _appRuntime = State(initialValue: appRuntime)
    self.modelPricingService = modelPricingService
    #if os(macOS)
      appDelegate.configure(
        appRuntime: appRuntime,
        modelPricingService: modelPricingService
      )
    #else
      appDelegate.configure(appRuntime: appRuntime)
    #endif
  }

  var body: some Scene {
    #if os(macOS)
      WindowGroup(id: AppRuntimeMode.isRunningTestsProcess ? "test-host" : "main") {
        if AppRuntimeMode.isRunningTestsProcess {
          Color.clear
            .frame(minWidth: 1, maxWidth: .infinity, minHeight: 1, maxHeight: .infinity)
        } else {
          OrbitDockWindowRoot(appRuntime: appRuntime)
            .environment(appRuntime)
            .environment(\.modelPricingService, modelPricingService)
            .frame(minWidth: 1_000, maxWidth: .infinity, minHeight: 700, maxHeight: .infinity)
        }
      }
      .windowStyle(.hiddenTitleBar)
      .defaultSize(width: 1_400, height: 800)
      .commands { OrbitDockWindowCommands() }

      MenuBarExtra {
        if AppRuntimeMode.isRunningTestsProcess {
          Color.clear
            .frame(width: 1, height: 1)
        } else {
          MenuBarView()
            .environment(\.modelPricingService, modelPricingService)
            .environment(appRuntime.runtimeRegistry)
            .environment(appRuntime.usageServiceRegistry)
            .environment(appRuntime.sessionsSummaryDataService)
            .environment(appRuntime)
            .environment(\.colorScheme, .dark)
            .preferredColorScheme(.dark)
        }
      } label: {
        Image(systemName: "terminal.fill")
          .symbolRenderingMode(.monochrome)
      }
      .menuBarExtraStyle(.window)
    #else
      WindowGroup {
        if AppRuntimeMode.isRunningTestsProcess {
          Color.clear
            .frame(minWidth: 1, maxWidth: .infinity, minHeight: 1, maxHeight: .infinity)
        } else {
          OrbitDockWindowRoot(appRuntime: appRuntime)
            .environment(appRuntime)
            .environment(\.modelPricingService, modelPricingService)
        }
      }
      .onChange(of: scenePhase) { _, newPhase in
        guard !AppRuntimeMode.isRunningTestsProcess else { return }
        appRuntime.focusTracker.update(scenePhase: newPhase)
        switch newPhase {
          case .active:
            appRuntime.runtimeRegistry.resumeFromBackgroundIfNeeded()
          case .background:
            appRuntime.runtimeRegistry.suspendForBackground()
          case .inactive:
            break
          @unknown default:
            break
        }
      }
    #endif
  }
}

struct OrbitDockWindowCommands: Commands {
  @FocusedValue(\.orbitDockRouter) private var router
  @FocusedValue(\.sessionDetailTerminalToggle) private var toggleTerminal
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandGroup(replacing: .appSettings) {
      Button("Settings...") {
        router?.goToSettings(source: .commandMenu)
      }
      .keyboardShortcut(",", modifiers: .command)
      .disabled(router == nil)
    }

    CommandGroup(replacing: .newItem) {
      Button("New Session") {
        openNewSessionSheet()
      }
      .keyboardShortcut("n", modifiers: .command)
      .disabled(router == nil)

      Button("New Window") {
        openWindow(id: "main")
      }
      .keyboardShortcut("n", modifiers: [.command, .shift])
    }

    CommandGroup(after: .toolbar) {
      Button("Dashboard") {
        router?.goToDashboard(source: .commandMenu)
      }
      .keyboardShortcut("0", modifiers: .command)
      .disabled(router == nil)

      Button("Quick Switch") {
        router?.openQuickSwitcher()
      }
      .keyboardShortcut("k", modifiers: .command)
      .disabled(router == nil)

      Button("Terminal") {
        toggleTerminal?()
      }
      .keyboardShortcut("t", modifiers: .command)
      .disabled(toggleTerminal == nil)
    }
  }

  private func openNewSessionSheet() {
    #if os(macOS)
      focusPrimaryWindowForModalPresentation()
    #endif
    router?.openNewSessionSheet()
  }

  #if os(macOS)
    private func focusPrimaryWindowForModalPresentation() {
      if let window = NSApp.windows.first(where: isPrimaryAppWindow) {
        NSApp.activate(ignoringOtherApps: true)
        if NSApp.keyWindow !== window {
          window.makeKeyAndOrderFront(nil)
        }
      } else {
        openWindow(id: "main")
      }
    }

    private func isPrimaryAppWindow(_ window: NSWindow) -> Bool {
      let className = String(describing: type(of: window))
      if className.contains("NSStatusBarWindow") {
        return false
      }
      return window.canBecomeKey && window.isVisible
    }
  #endif
}

#if os(iOS)
  class iOSAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private var appRuntime: OrbitDockAppRuntime?

    func configure(appRuntime: OrbitDockAppRuntime) {
      self.appRuntime = appRuntime
    }

    func application(
      _ application: UIApplication,
      didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
      guard !AppRuntimeMode.isRunningTestsProcess else { return true }
      appRuntime?.notificationCoordinator.configureCategories(delegate: self)
      return true
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
        appRuntime?.externalNavigationCenter.submitSessionSelection(
          sessionId: sessionId,
          endpointId: nil
        )
      }

      completionHandler()
    }
  }
#endif

#if os(macOS)
  class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var appRuntime: OrbitDockAppRuntime?
    private var modelPricingService: ModelPricingService?

    func configure(
      appRuntime: OrbitDockAppRuntime,
      modelPricingService: ModelPricingService
    ) {
      self.appRuntime = appRuntime
      self.modelPricingService = modelPricingService
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
      UserDefaults.standard.set(false, forKey: "NSTableViewCanEstimateRowHeights")
      NSApp.appearance = NSAppearance(named: .darkAqua)
      guard !AppRuntimeMode.isRunningTestsProcess else { return }
      AppFileLogger.shared.start()
      appRuntime?.notificationCoordinator.configureCategories(delegate: self)
    }

    func applicationWillTerminate(_ notification: Notification) {
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
      NSApp.activate(ignoringOtherApps: true)

      let userInfo = response.notification.request.content.userInfo
      if let sessionId = userInfo["sessionId"] as? String {
        appRuntime?.externalNavigationCenter.submitSessionSelection(
          sessionId: sessionId,
          endpointId: nil
        )
      }

      completionHandler()
    }
  }
#endif
