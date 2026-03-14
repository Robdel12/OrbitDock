import SwiftUI

struct OrbitDockWindowRoot: View {
  let appRuntime: OrbitDockAppRuntime
  @State private var appStore: AppStore
  @State private var router = AppRouter()
  @State private var toastManager = ToastManager()

  init(appRuntime: OrbitDockAppRuntime) {
    self.appRuntime = appRuntime
    _appStore = State(initialValue: AppStore(connection: appRuntime.runtimeRegistry.primaryConnection))
  }

  var body: some View {
    NavigationSplitView {
      sidebar
    } detail: {
      detail
    }
    .navigationSplitViewStyle(.balanced)
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
    .task {
      appStore.start()
    }
  }

  // MARK: - Sidebar: Dashboard with session list

  private var sidebar: some View {
    DashboardView(
      isInitialLoading: false,
      isRefreshingCachedSessions: false
    )
    #if os(macOS)
      .navigationSplitViewColumnWidth(min: 600, ideal: 700, max: .infinity)
    #endif
    .toolbar(.hidden)
  }

  // MARK: - Detail: Session conversation when selected

  @ViewBuilder
  private var detail: some View {
    if let ref = router.selectedSessionRef {
      SessionDetailView(
        sessionId: ref.sessionId,
        endpointId: ref.endpointId
      )
      .environment(detailSessionStore(for: ref.endpointId))
      .id(ref.scopedID)
      .toolbar(.hidden)
    } else {
      ContentUnavailableView(
        "Select a Session",
        systemImage: "bubble.left.and.bubble.right",
        description: Text("Choose an agent session from the sidebar")
      )
    }
  }

  private func detailSessionStore(for endpointId: UUID) -> SessionStore {
    let fallback = appRuntime.runtimeRegistry.activeSessionStore
    return appRuntime.runtimeRegistry.sessionStore(for: endpointId, fallback: fallback)
  }
}
