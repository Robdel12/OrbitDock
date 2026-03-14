import SwiftUI
import UserNotifications
#if os(macOS)
  import AppKit
#endif

@main
struct OrbitDockApp: App {
  #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
  #endif
  @State private var appRuntime = OrbitDockAppRuntime()
  private let modelPricingService: ModelPricingService

  init() {
    let modelPricingService = ModelPricingService.live()
    self.modelPricingService = modelPricingService
    #if os(macOS)
      appDelegate.configure(appRuntime: _appRuntime.wrappedValue, modelPricingService: modelPricingService)
    #endif
  }

  var body: some Scene {
    #if os(macOS)
      WindowGroup {
        OrbitDockWindowRoot(appRuntime: appRuntime)
          .environment(\.modelPricingService, modelPricingService)
          .frame(minWidth: 1_000, maxWidth: .infinity, minHeight: 700, maxHeight: .infinity)
          .task {
            await appRuntime.startIfNeeded()
          }
      }
      .windowStyle(.hiddenTitleBar)
      .defaultSize(width: 1_400, height: 800)
      .commands {
        OrbitDockWindowCommands()
      }
    #else
      WindowGroup {
        OrbitDockWindowRoot(appRuntime: appRuntime)
          .environment(\.modelPricingService, modelPricingService)
          .task {
            await appRuntime.startIfNeeded()
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
        router?.goToDashboard()
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
