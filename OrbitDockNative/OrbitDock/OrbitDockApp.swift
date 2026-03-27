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
  #if os(macOS)
    @State private var menuBarAppStore: AppStore
  #endif
  private let modelPricingService: ModelPricingService

  init() {
    let appRuntime = OrbitDockAppRuntime()
    let modelPricingService = ModelPricingService.live()
    _appRuntime = State(initialValue: appRuntime)
    self.modelPricingService = modelPricingService
    #if os(macOS)
      _menuBarAppStore = State(
        initialValue: AppStore(runtimeRegistry: appRuntime.runtimeRegistry)
      )
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
      WindowGroup {
        OrbitDockWindowRoot(appRuntime: appRuntime)
          .environment(appRuntime)
          .environment(\.modelPricingService, modelPricingService)
          .frame(minWidth: 1_000, maxWidth: .infinity, minHeight: 700, maxHeight: .infinity)
          .task {
            await appRuntime.startIfNeeded()
          }
      }
      .windowStyle(.hiddenTitleBar)
      .defaultSize(width: 1_400, height: 800)
      .commands { OrbitDockWindowCommands() }

      Settings {
        SettingsView()
          .environment(appRuntime.runtimeRegistry.activeSessionStore)
          .environment(\.modelPricingService, modelPricingService)
          .environment(appRuntime.runtimeRegistry)
          .environment(appRuntime.notificationCoordinator)
          .preferredColorScheme(.dark)
      }

      MenuBarExtra {
        MenuBarView()
          .environment(\.modelPricingService, modelPricingService)
          .environment(appRuntime.runtimeRegistry)
          .environment(appRuntime.usageServiceRegistry)
          .environment(menuBarAppStore)
          .environment(\.colorScheme, .dark)
          .preferredColorScheme(.dark)
      } label: {
        Image(systemName: "terminal.fill")
          .symbolRenderingMode(.monochrome)
      }
      .menuBarExtraStyle(.window)
    #else
      WindowGroup {
        OrbitDockWindowRoot(appRuntime: appRuntime)
          .environment(appRuntime)
          .environment(\.modelPricingService, modelPricingService)
          .task {
            await appRuntime.startIfNeeded()
          }
      }
      .onChange(of: scenePhase) { _, newPhase in
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

  var body: some Commands {
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
    }
  }
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
