import SwiftUI

struct OrbitDockWindowRoot: View {
  let appRuntime: OrbitDockAppRuntime
  @State private var attentionService: AttentionService
  @State private var notificationManager: NotificationManager
  @State private var router: AppRouter
  @State private var toastManager: ToastManager
  @State private var windowSessionCoordinator: WindowSessionCoordinator

  init(appRuntime: OrbitDockAppRuntime) {
    self.appRuntime = appRuntime

    let attentionService = AttentionService()
    let notificationManager = NotificationManager.shared
    let router = AppRouter()
    let toastManager = ToastManager()
    _attentionService = State(initialValue: attentionService)
    _notificationManager = State(initialValue: notificationManager)
    _router = State(initialValue: router)
    _toastManager = State(initialValue: toastManager)
    _windowSessionCoordinator = State(
      initialValue: WindowSessionCoordinator(
        runtimeRegistry: appRuntime.runtimeRegistry,
        attentionService: attentionService,
        notificationManager: notificationManager,
        toastManager: toastManager,
        router: router
      )
    )
  }

  var body: some View {
    ContentView()
      .environment(appRuntime.runtimeRegistry.activeSessionStore)
      .environment(appRuntime.runtimeRegistry)
      .environment(appRuntime.usageServiceRegistry)
      .environment(attentionService)
      .environment(router)
      .environment(windowSessionCoordinator)
      .focusedSceneValue(\.orbitDockRouter, router)
      .preferredColorScheme(.dark)
    #if os(iOS)
      .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
        appRuntime.runtimeRegistry.handleMemoryPressure()
        MarkdownSystemParser.clearCache()
        SyntaxHighlighter.clearCache()
      }
    #endif
  }
}
