import SwiftUI

struct OrbitDockWindowRoot: View {
  let appRuntime: OrbitDockAppRuntime
  @State private var appStore: AppStore
  @State private var router = AppRouter()
  @State private var toastManager = ToastManager()
  @State private var navigationPath = NavigationPath()

  init(appRuntime: OrbitDockAppRuntime) {
    self.appRuntime = appRuntime
    _appStore = State(initialValue: AppStore(runtimeRegistry: appRuntime.runtimeRegistry))
  }

  var body: some View {
    ZStack {
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
        .navigationDestination(for: MissionRef.self) { ref in
          MissionShowView(
            missionId: ref.missionId,
            endpointId: ref.endpointId
          )
          .id(ref.id)
        }
      }

      if router.showQuickSwitcher {
        quickSwitcherOverlay
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
    .focusable()
    .onKeyPress(keys: [.escape]) { _ in
      guard router.showQuickSwitcher else { return .ignored }
      withAnimation(Motion.standard) {
        router.closeQuickSwitcher()
      }
      return .handled
    }
    .preferredColorScheme(.dark)
    .toolbar(.hidden)
    .onChange(of: router.route) { oldRoute, newRoute in
      guard oldRoute != newRoute else { return }

      switch newRoute {
        case let .session(ref):
          // Unsubscribe from previous session before subscribing to the new one
          if case let .session(oldRef) = oldRoute {
            detailSessionStore(for: oldRef.endpointId)
              .unsubscribeFromSession(oldRef.sessionId)
          }
          navigationPath = NavigationPath([ref])
          detailSessionStore(for: ref.endpointId)
            .subscribeToSession(ref.sessionId)

        case let .mission(ref):
          if case let .session(oldRef) = oldRoute {
            detailSessionStore(for: oldRef.endpointId)
              .unsubscribeFromSession(oldRef.sessionId)
          }
          navigationPath = NavigationPath([ref])

        case .dashboard:
          // Pop instantly — no slide animation. Unsubscribe after the view
          // is removed so clearing the store doesn't trigger competing
          // animations inside the outgoing ConversationView.
          var t = Transaction(animation: nil)
          t.disablesAnimations = true
          withTransaction(t) {
            navigationPath = NavigationPath()
          }
          if case let .session(oldRef) = oldRoute {
            Task { @MainActor in
              detailSessionStore(for: oldRef.endpointId)
                .unsubscribeFromSession(oldRef.sessionId)
            }
          }
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
      .environment(creationStore())
      .environment(appRuntime.runtimeRegistry)
      .environment(router)
      .environment(appStore)
      #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
      #endif
    }
  }

  // MARK: - Quick Switcher Overlay

  private var quickSwitcherOverlay: some View {
    ZStack {
      Color.black.opacity(0.5)
        .ignoresSafeArea()
        .onTapGesture {
          withAnimation(Motion.standard) {
            router.closeQuickSwitcher()
          }
        }

      QuickSwitcher(
        onQuickLaunchClaude: { path in
          Task {
            try? await creationStore().createSession(
              SessionsClient.CreateSessionRequest(provider: "claude", cwd: path)
            )
          }
        },
        onQuickLaunchCodex: { path in
          let targetState = creationStore()
          let defaultModel = targetState.codexModels.first(where: { $0.isDefault })?.model
            ?? targetState.codexModels.first?.model ?? ""
          Task {
            try? await targetState.createSession(
              SessionsClient.CreateSessionRequest(
                provider: "codex",
                cwd: path,
                model: defaultModel,
                approvalPolicy: "on-request",
                sandboxMode: "workspace-write"
              )
            )
          }
        }
      )
    }
    .transition(.opacity)
  }

  private func creationStore() -> SessionStore {
    let fallback = appRuntime.runtimeRegistry.activeSessionStore
    let preferredEndpointId = router.selectedEndpointId ?? router.selectedSessionRef?.endpointId
    let primaryStore = appRuntime.runtimeRegistry.primarySessionStore(fallback: fallback)
    return appRuntime.runtimeRegistry.sessionStore(for: preferredEndpointId, fallback: primaryStore)
  }

  private func detailSessionStore(for endpointId: UUID) -> SessionStore {
    let fallback = appRuntime.runtimeRegistry.activeSessionStore
    return appRuntime.runtimeRegistry.sessionStore(for: endpointId, fallback: fallback)
  }
}
