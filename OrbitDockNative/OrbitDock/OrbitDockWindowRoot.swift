import SwiftUI

struct OrbitDockWindowRoot: View {
  let appRuntime: OrbitDockAppRuntime
  @State private var appStore: AppStore
  @State private var router = AppRouter()
  @State private var toastManager = ToastManager()
  @State private var navigationPath = NavigationPath()

  init(appRuntime: OrbitDockAppRuntime) {
    self.appRuntime = appRuntime
    _appStore = State(initialValue: AppStore(connection: appRuntime.runtimeRegistry.primaryConnection))
  }

  var body: some View {
    NavigationStack(path: $navigationPath) {
      DashboardView(
        isInitialLoading: false,
        isRefreshingCachedSessions: false
      )
      .navigationDestination(for: SessionRef.self) { ref in
        SessionDetailView(
          sessionId: ref.sessionId,
          endpointId: ref.endpointId
        )
        .environment(detailSessionStore(for: ref.endpointId))
        .id(ref.scopedID)
      }
    }
    #if os(macOS)
      .environment(\.serverManager, appRuntime.serverManager)
    #endif
    .environment(appRuntime.runtimeRegistry)
    .environment(appRuntime.usageServiceRegistry)
    .environment(appRuntime.notificationManager)
    .environment(router)
    .environment(toastManager)
    .environment(appStore)
    .environment(\.rootSessionActions, RootSessionActions(runtimeRegistry: appRuntime.runtimeRegistry))
    .environment(\.modelPricingService, ModelPricingService.live())
    .focusedSceneValue(\.orbitDockRouter, router)
    .preferredColorScheme(.dark)
    .toolbar(.hidden)
    .task {
      appStore.start()
    }
    .onChange(of: router.route) { _, newRoute in
      switch newRoute {
      case let .session(ref):
        navigationPath = NavigationPath([ref])
      case .dashboard:
        navigationPath = NavigationPath()
      }
    }
    .sheet(isPresented: Binding(
      get: { router.showNewSessionSheet },
      set: { if !$0 { router.closeNewSessionSheet() } }
    )) {
      NewSessionSheet(
        provider: router.newSessionProvider,
        continuation: router.newSessionContinuation
      )
      .environment(appStore)
      #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
      #endif
    }
  }

  private func detailSessionStore(for endpointId: UUID) -> SessionStore {
    let fallback = appRuntime.runtimeRegistry.activeSessionStore
    return appRuntime.runtimeRegistry.sessionStore(for: endpointId, fallback: fallback)
  }
}
