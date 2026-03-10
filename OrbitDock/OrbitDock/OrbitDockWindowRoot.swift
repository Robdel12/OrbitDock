import SwiftUI

struct OrbitDockWindowRoot: View {
  let runtimeRegistry: ServerRuntimeRegistry
  let usageServiceRegistry: UsageServiceRegistry
  @State private var attentionService: AttentionService
  @State private var router: AppRouter
  @State private var toastManager: ToastManager
  @State private var windowSessionCoordinator: WindowSessionCoordinator

  init(runtimeRegistry: ServerRuntimeRegistry, usageServiceRegistry: UsageServiceRegistry) {
    self.runtimeRegistry = runtimeRegistry
    self.usageServiceRegistry = usageServiceRegistry

    let attentionService = AttentionService()
    let router = AppRouter()
    let toastManager = ToastManager()
    _attentionService = State(initialValue: attentionService)
    _router = State(initialValue: router)
    _toastManager = State(initialValue: toastManager)
    _windowSessionCoordinator = State(
      initialValue: WindowSessionCoordinator(
        runtimeRegistry: runtimeRegistry,
        attentionService: attentionService,
        toastManager: toastManager,
        router: router
      )
    )
  }

  var body: some View {
    ContentView()
      .environment(runtimeRegistry.activeSessionStore)
      .environment(runtimeRegistry)
      .environment(usageServiceRegistry)
      .environment(attentionService)
      .environment(router)
      .environment(windowSessionCoordinator)
      .preferredColorScheme(.dark)
      .onReceive(NotificationCenter.default.publisher(for: .navigateToDashboard)) { _ in
        router.goToDashboard()
      }
      .onReceive(NotificationCenter.default.publisher(for: .navigateToLibrary)) { _ in
        router.goToLibrary()
      }
      .onReceive(NotificationCenter.default.publisher(for: .openQuickSwitcher)) { _ in
        router.openQuickSwitcher()
      }
    #if os(iOS)
      .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
        runtimeRegistry.handleMemoryPressure()
        MarkdownSystemParser.clearCache()
        SyntaxHighlighter.clearCache()
      }
    #endif
  }
}
