import SwiftUI

struct OrbitDockWindowRoot: View {
  @Environment(OrbitDockAppRuntime.self) private var environmentAppRuntime
  let appRuntime: OrbitDockAppRuntime
  @State private var appStore: AppStore
  @State private var router = AppRouter()
  @State private var terminalRegistry = TerminalSessionRegistry()
  @State private var externalNavWindowID = UUID()

  private var shouldShowSetup: Bool {
    !appRuntime.isDemoModeEnabled && !appRuntime.runtimeRegistry.hasConfiguredEndpoints
  }

  init(appRuntime: OrbitDockAppRuntime) {
    self.appRuntime = appRuntime
    _appStore = State(initialValue: AppStore(runtimeRegistry: appRuntime.runtimeRegistry))
  }

  var body: some View {
    ZStack {
      if shouldShowSetup {
        ServerSetupView()
      } else {
        NavigationStack(path: Binding(get: { router.navigationStack }, set: { router.navigationStack = $0 })) {
          DashboardView(
            isInitialLoading: appRuntime.runtimeRegistry.runtimes
              .filter(\.endpoint.isEnabled)
              .contains { runtime in
                let readiness = appRuntime.runtimeRegistry.runtimeReadiness(for: runtime.endpoint.id)
                return switch runtime.connection.connectionStatus {
                  case .connecting, .connected:
                    !readiness.dashboardReady
                  case .disconnected, .failed:
                    false
                }
              },
            isRefreshingCachedSessions: false
          )
          .navigationDestination(for: AppNavDestination.self) { destination in
            switch destination {
              case let .session(ref):
                SessionDetailView(
                  sessionId: ref.sessionId,
                  endpointId: ref.endpointId,
                  sessionStore: detailSessionStore(for: ref.endpointId)
                )
                .id(ref.scopedID)
              case let .mission(ref):
                MissionShowView(
                  missionId: ref.missionId,
                  endpointId: ref.endpointId
                )
                .id(ref.id)
              case let .terminal(terminalId):
                if let session = terminalRegistry.session(for: terminalId) {
                  TerminalContainerView(session: session)
                    .id(terminalId)
                }
            }
          }
        }
      }

      if router.showQuickSwitcher {
        quickSwitcherOverlay
      }
    }
    .environment(appRuntime.runtimeRegistry)
    .environment(appRuntime.usageServiceRegistry)
    .environment(appRuntime.notificationCoordinator)
    .environment(appRuntime)
    .environment(router)
    .environment(terminalRegistry)
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
    .onAppear {
      syncDemoSeed()

      // Register for external navigation (notification taps, etc.)
      appRuntime.externalNavigationCenter.registerWindow(externalNavWindowID) { command in
        switch command {
          case let .selectSession(sessionId, _):
            router.navigateToSession(scopedID: sessionId, source: .external)
        }
      }
      appRuntime.externalNavigationCenter.updateFocusedWindow(externalNavWindowID)
    }
    .onDisappear {
      appRuntime.externalNavigationCenter.unregisterWindow(externalNavWindowID)
    }
    .onChange(of: environmentAppRuntime.isDemoModeEnabled) { _, _ in
      syncDemoSeed()
    }
    .onChange(of: appStore.dashboardProjectionStore.rootSessions) { oldSessions, newSessions in
      if oldSessions.isEmpty, !newSessions.isEmpty {
        // First load — seed baseline to avoid a burst of toasts
        appRuntime.notificationCoordinator.seedBaseline(newSessions)
      } else {
        appRuntime.notificationCoordinator.processSessionUpdate(newSessions)
      }
    }
    .onChange(of: appRuntime.focusTracker.isAppActive) { _, isActive in
      appRuntime.notificationCoordinator.appIsActive = isActive
    }
    .onChange(of: router.route) { oldRoute, newRoute in
      guard oldRoute != newRoute else { return }

      // Update notification coordinator's viewed session
      if case let .session(ref) = newRoute {
        appRuntime.notificationCoordinator.viewedSessionScopedID = ref.scopedID
      } else {
        appRuntime.notificationCoordinator.viewedSessionScopedID = nil
      }

      switch newRoute {
        case let .session(ref):
          // Unsubscribe from previous session before subscribing to the new one
          if case let .session(oldRef) = oldRoute {
            detailSessionStore(for: oldRef.endpointId)
              .unsubscribeFromSession(oldRef.sessionId)
          }
          detailSessionStore(for: ref.endpointId)
            .subscribeToSession(
              ref.sessionId,
              surfaces: [.detail, .composer, .conversation]
            )

        case .mission:
          if case let .session(oldRef) = oldRoute {
            detailSessionStore(for: oldRef.endpointId)
              .unsubscribeFromSession(oldRef.sessionId)
          }

        case .terminal:
          if case let .session(oldRef) = oldRoute {
            detailSessionStore(for: oldRef.endpointId)
              .unsubscribeFromSession(oldRef.sessionId)
          }

        case .dashboard:
          // Unsubscribe after the view is removed so clearing the store
          // doesn't trigger competing animations in the outgoing ConversationView.
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
        continuation: router.newSessionContinuation,
        sessionStore: creationStore()
      )
      .environment(appRuntime.runtimeRegistry)
      .environment(router)
      .environment(appStore)
      #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
      #endif
    }
    .motionPolicy()
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
    if appRuntime.isDemoModeEnabled {
      return appRuntime.demoExperience.sessionStore
    }
    let fallback = appRuntime.runtimeRegistry.activeSessionStore
    let preferredEndpointId = router.selectedEndpointId ?? router.selectedSessionRef?.endpointId
    let primaryStore = appRuntime.runtimeRegistry.primarySessionStore(fallback: fallback)
    return appRuntime.runtimeRegistry.sessionStore(for: preferredEndpointId, fallback: primaryStore)
  }

  private func detailSessionStore(for endpointId: UUID) -> SessionStore {
    if appRuntime.isDemoModeEnabled, endpointId == appRuntime.demoExperience.endpoint.id {
      return appRuntime.demoExperience.sessionStore
    }
    let fallback = appRuntime.runtimeRegistry.activeSessionStore
    return appRuntime.runtimeRegistry.sessionStore(for: endpointId, fallback: fallback)
  }

  private func syncDemoSeed() {
    if appRuntime.isDemoModeEnabled {
      let demo = appRuntime.demoExperience
      appStore.seed(records: demo.rootSessions)
      appStore.seedDashboardConversations(demo.dashboardConversations)

      // Push demo data into the projection store so DashboardViewModel sees it.
      // applyDemo blocks real registry updates until clearDemoOverride is called.
      let snapshot = DashboardProjectionBuilder.build(
        rootSessions: demo.rootSessions,
        dashboardConversations: demo.dashboardConversations,
        refreshIdentity: "demo-\(UUID().uuidString.prefix(8))"
      )
      appStore.dashboardProjectionStore.applyDemo(snapshot)
      return
    }
    appStore.dashboardProjectionStore.clearDemoOverride()
    appStore.clearPreviewSeed()
  }
}
