import SwiftUI

struct OrbitDockWindowRoot: View {
  @State private var attentionService = AttentionService()
  @State private var router = AppRouter()
  let runtimeRegistry: ServerRuntimeRegistry
  let usageServiceRegistry: UsageServiceRegistry

  private var sessionStore: SessionStore {
    runtimeRegistry.activeSessionStore
  }

  var body: some View {
    ContentView()
      .environment(sessionStore)
      .environment(runtimeRegistry)
      .environment(usageServiceRegistry)
      .environment(attentionService)
      .environment(router)
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
