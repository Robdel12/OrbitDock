import SwiftUI

struct OrbitDockWindowRoot: View {
  let appRuntime: OrbitDockAppRuntime
  @State private var router = AppRouter()
  @State private var dashboardDataService: DashboardDataService
  @State private var libraryDataService: LibraryDataService
  @State private var dashboardViewModel: DashboardViewModel
  @State private var terminalRegistry = TerminalSessionRegistry()
  @State private var externalNavWindowID = UUID()
  @State private var sidebarVisibility: NavigationSplitViewVisibility = .automatic
  @State private var preferredColumn: NavigationSplitViewColumn = .detail

  private var shouldShowSetup: Bool {
    !appRuntime.isDemoModeEnabled && !appRuntime.runtimeRegistry.hasConfiguredEndpoints
  }

  init(appRuntime: OrbitDockAppRuntime) {
    self.appRuntime = appRuntime
    let dashboardDataService = DashboardDataService()
    let libraryDataService = LibraryDataService()
    _dashboardDataService = State(initialValue: dashboardDataService)
    _libraryDataService = State(initialValue: libraryDataService)
    _dashboardViewModel = State(initialValue: DashboardViewModel(dataService: dashboardDataService))
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
    .environment(appRuntime.sessionsSummaryDataService)
    .environment(dashboardDataService)
    .environment(libraryDataService)
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
    .background {
      OrbitDockWindowCoordinator(
        appRuntime: appRuntime,
        router: router,
        dashboardDataService: dashboardDataService,
        libraryDataService: libraryDataService,
        externalNavWindowID: externalNavWindowID,
        preferredColumn: $preferredColumn
      )
    }
    .sheet(isPresented: Binding(
      get: { router.showNewSessionSheet },
      set: { if !$0 { router.closeNewSessionSheet() } }
    )) {
      NewSessionSheet(
        provider: router.newSessionProvider,
        continuation: router.newSessionContinuation,
        endpointStore: creationStore()
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
          session: detailSession(for: ref)
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

  private func creationStore() -> ServerEndpointRuntime {
    if appRuntime.isDemoModeEnabled {
      return appRuntime.demoExperience.endpointStore
    }
    let preferredEndpointId = router.selectedEndpointId ?? router.selectedSessionRef?.endpointId
    return appRuntime.runtimeRegistry.preferredCreationEndpointStore(
      preferredEndpointId: preferredEndpointId
    )
  }

  private func detailSession(for ref: SessionRef) -> ServerSessionContext {
    if appRuntime.isDemoModeEnabled, ref.endpointId == appRuntime.demoExperience.endpoint.id {
      return appRuntime.demoExperience.endpointStore.session(ref.sessionId)
    }
    let endpointStore = appRuntime.runtimeRegistry.endpointStore(for: ref.endpointId)
    return endpointStore.session(ref.sessionId)
  }
}
