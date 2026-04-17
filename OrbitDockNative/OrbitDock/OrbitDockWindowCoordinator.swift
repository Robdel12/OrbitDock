import SwiftUI

struct OrbitDockWindowCoordinator: View {
  let appRuntime: OrbitDockAppRuntime
  let router: AppRouter
  let dashboardDataService: DashboardDataService
  let libraryDataService: LibraryDataService
  let externalNavWindowID: UUID
  @Binding var preferredColumn: NavigationSplitViewColumn
  @State private var hasSeededNotificationBaseline = false

  var body: some View {
    Color.clear
      .task(id: appRuntime.runtimeRegistry.hasConfiguredEndpoints) {
        await configureDataServices()
      }
      .onAppear {
        registerExternalNavigation()
      }
      .onDisappear {
        dashboardDataService.stop()
        libraryDataService.stopLiveUpdates()
        appRuntime.externalNavigationCenter.unregisterWindow(externalNavWindowID)
      }
      .onChange(of: appRuntime.sessionsSummaryDataService.summaryRevision) { _, _ in
        handleSessionsSummaryChange()
      }
      .onChange(of: appRuntime.focusTracker.isAppActive) { _, isActive in
        appRuntime.notificationCoordinator.appIsActive = isActive
      }
      .onChange(of: router.workspaceSelection) { oldSelection, newSelection in
        handleWorkspaceSelectionChange(oldSelection: oldSelection, newSelection: newSelection)
      }
  }

  private func configureDataServices() async {
    await appRuntime.startIfNeeded()

    if appRuntime.runtimeRegistry.hasConfiguredEndpoints {
      dashboardDataService.start(runtimeRegistry: appRuntime.runtimeRegistry)
    } else {
      dashboardDataService.stop()
    }

    guard appRuntime.isDemoModeEnabled else { return }
    let conversations = appRuntime.demoExperience.dashboardConversations
    dashboardDataService.applyDemoSnapshot(
      DashboardSnapshot(
        revision: 0,
        conversations: conversations,
        counts: DashboardTriageCounts(conversations: conversations),
        directCount: conversations.filter(\.isDirect).count,
        hasMultipleEndpoints: false,
        projectGroups: []
      )
    )
    appRuntime.sessionsSummaryDataService.applyDemoSessions(appRuntime.demoExperience.rootSessions)
    libraryDataService.applyDemoSessions(appRuntime.demoExperience.rootSessions)
    seedOrProcessNotifications(with: appRuntime.demoExperience.rootSessions)
  }

  private func registerExternalNavigation() {
    appRuntime.externalNavigationCenter.registerWindow(externalNavWindowID) { command in
      switch command {
        case let .selectSession(sessionId, _):
          router.navigateToSession(scopedID: sessionId, source: .external)
      }
    }
    appRuntime.externalNavigationCenter.updateFocusedWindow(externalNavWindowID)
  }

  private func handleSessionsSummaryChange() {
    seedOrProcessNotifications(with: appRuntime.sessionsSummaryDataService.compactSessions())
  }

  private func handleWorkspaceSelectionChange(
    oldSelection: WorkspaceSelection,
    newSelection: WorkspaceSelection
  ) {
    guard oldSelection != newSelection else { return }

    preferredColumn = .detail

    if case let .session(ref) = newSelection {
      appRuntime.notificationCoordinator.viewedSessionScopedID = ref.scopedID
    } else {
      appRuntime.notificationCoordinator.viewedSessionScopedID = nil
    }
  }

  private func seedOrProcessNotifications(with sessions: [RootSessionNode]) {
    if !hasSeededNotificationBaseline {
      appRuntime.notificationCoordinator.seedBaseline(sessions)
      hasSeededNotificationBaseline = true
      return
    }

    appRuntime.notificationCoordinator.processSessionUpdate(sessions)
  }
}
