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
    @Environment(\.scenePhase) private var scenePhase
  #endif
  @State private var appRuntime: OrbitDockAppRuntime
  #if os(macOS)
    @State private var appUpdater: AppUpdater
    @State private var menuBarAppStore: AppStore
  #endif
  private let modelPricingService: ModelPricingService

  init() {
    let appRuntime = OrbitDockAppRuntime()
    let modelPricingService = ModelPricingService.live()
    _appRuntime = State(initialValue: appRuntime)
    self.modelPricingService = modelPricingService
    #if os(macOS)
      let appUpdater = AppUpdater()
      _appUpdater = State(initialValue: appUpdater)
      _menuBarAppStore = State(
        initialValue: AppStore(runtimeRegistry: appRuntime.runtimeRegistry)
      )
      appDelegate.configure(
        appRuntime: appRuntime,
        modelPricingService: modelPricingService,
        appUpdater: appUpdater
      )
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
      .commands {
        OrbitDockWindowCommands(appUpdater: appUpdater)
      }

      Settings {
        SettingsView()
          .environment(\.serverManager, appRuntime.serverManager)
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
  #if os(macOS)
    @Bindable var appUpdater: AppUpdater
  #endif

  var body: some Commands {
    #if os(macOS)
      CommandGroup(after: .appInfo) {
        Button("Check for Updates...") {
          appUpdater.checkForUpdates()
        }
        .disabled(!appUpdater.canCheckForUpdates)
      }
    #endif

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

#if os(macOS)
  class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var appRuntime: OrbitDockAppRuntime?
    private var modelPricingService: ModelPricingService?
    private var appUpdater: AppUpdater?

    func configure(
      appRuntime: OrbitDockAppRuntime,
      modelPricingService: ModelPricingService,
      appUpdater: AppUpdater
    ) {
      self.appRuntime = appRuntime
      self.modelPricingService = modelPricingService
      self.appUpdater = appUpdater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
      UserDefaults.standard.set(false, forKey: "NSTableViewCanEstimateRowHeights")
      NSApp.appearance = NSAppearance(named: .darkAqua)
      guard !AppRuntimeMode.isRunningTestsProcess else { return }
      AppFileLogger.shared.start()
      appRuntime?.notificationManager.configureAppSessionNotifications(delegate: self)
      appUpdater?.start()
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
      completionHandler()
    }
  }
#endif
