import SwiftUI

struct OrbitDockWindowRoot: View {
  @Environment(OrbitDockAppRuntime.self) private var environmentAppRuntime
  let appRuntime: OrbitDockAppRuntime
  @State private var router = AppRouter()
  @State private var dashboardViewModel: DashboardViewModel
  @State private var terminalRegistry = TerminalSessionRegistry()
  @State private var notificationSessionMonitor = NotificationSessionMonitor()
  @State private var externalNavWindowID = UUID()
  @State private var sidebarVisibility: NavigationSplitViewVisibility = .automatic
  @State private var preferredColumn: NavigationSplitViewColumn = .detail

  private var shouldShowSetup: Bool {
    !appRuntime.isDemoModeEnabled && !appRuntime.runtimeRegistry.hasConfiguredEndpoints
  }

  init(appRuntime: OrbitDockAppRuntime) {
    self.appRuntime = appRuntime
    _dashboardViewModel = State(initialValue: DashboardViewModel(dataService: appRuntime.dashboardDataService))
  }

  var body: some View {
    ZStack {
      if shouldShowSetup {
        ServerSetupView()
      } else {
        NavigationSplitView(columnVisibility: $sidebarVisibility, preferredCompactColumn: $preferredColumn) {
          SessionSidebar(viewModel: dashboardViewModel)
            .navigationSplitViewColumnWidth(min: 200, ideal: 244, max: 320)
        } detail: {
          workspaceContent
        }
        .navigationSplitViewStyle(.balanced)
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
    .environment(appRuntime.dashboardDataService)
    .environment(\.rootSessionActions, RootSessionActions(runtimeRegistry: appRuntime.runtimeRegistry))
    .environment(\.modelPricingService, ModelPricingService.live())
    .focusedSceneValue(\.orbitDockRouter, router)
    .focusable()
    .focusEffectDisabled()
    .onKeyPress(keys: [.escape]) { _ in
      guard router.showQuickSwitcher else { return .ignored }
      withAnimation(Motion.standard) {
        router.closeQuickSwitcher()
      }
      return .handled
    }
    .onKeyPress(characters: CharacterSet(charactersIn: "\\"), phases: .down) { press in
      guard press.modifiers == .command else { return .ignored }
      router.toggleSidebar()
      return .handled
    }
    .preferredColorScheme(.dark)
    #if os(macOS)
      .toolbar(removing: .title)
      .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    #endif
    .task {
      await appRuntime.startIfNeeded()

      if appRuntime.isDemoModeEnabled {
        let conversations = appRuntime.demoExperience.dashboardConversations
        dashboardViewModel.applySnapshot(DashboardSnapshot(
          revision: 0,
          conversations: conversations,
          counts: DashboardTriageCounts(conversations: conversations),
          directCount: conversations.filter(\.isDirect).count,
          hasMultipleEndpoints: false
        ))
        appRuntime.dashboardDataService.applyDemoSessions(appRuntime.demoExperience.rootSessions)
        notificationSessionMonitor.applySessions(appRuntime.demoExperience.rootSessions)
      }
    }
    .onAppear {
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
    .onChange(of: appRuntime.dashboardDataService.librarySessions) { oldSessions, newSessions in
      notificationSessionMonitor.applySessions(newSessions)
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
    .onChange(of: router.workspaceSelection) { oldSelection, newSelection in
      guard oldSelection != newSelection else { return }

      // On compact (iPhone), push to the detail column when selection changes.
      // On regular width this binding is ignored by NavigationSplitView.
      preferredColumn = .detail

      // Update notification coordinator's viewed session
      if case let .session(ref) = newSelection {
        appRuntime.notificationCoordinator.viewedSessionScopedID = ref.scopedID
      } else {
        appRuntime.notificationCoordinator.viewedSessionScopedID = nil
      }

      // Unsubscribe from previous session if leaving one
      if case let .session(oldRef) = oldSelection {
        if case .session = newSelection {
          // Navigating session → session: unsubscribe old before subscribing new
          detailSessionStore(for: oldRef.endpointId)
            .unsubscribeFromSession(oldRef.sessionId)
        } else {
          // Navigating session → non-session: defer unsubscribe
          Task { @MainActor in
            detailSessionStore(for: oldRef.endpointId)
              .unsubscribeFromSession(oldRef.sessionId)
          }
        }
      }

      // Subscribe to new session if entering one
      if case let .session(ref) = newSelection {
        detailSessionStore(for: ref.endpointId)
          .subscribeToSession(
            ref.sessionId,
            surfaces: [.detail, .composer, .conversation]
          )
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
      #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
      #endif
    }
    .motionPolicy()
  }

  // MARK: - Workspace Content

  @ViewBuilder
  private var workspaceContent: some View {
    switch router.workspaceSelection {
      case .overview, .missions, .library:
        DashboardView(viewModel: dashboardViewModel)
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
      case .settings:
        SettingsView()
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
}
