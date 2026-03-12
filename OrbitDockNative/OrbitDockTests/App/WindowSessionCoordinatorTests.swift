import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct WindowSessionCoordinatorTests {
  @Test func startBootstrapsRootShellAndTracksCurrentSelection() async throws {
    let endpoint = try makeEndpoint(
      id: "11111111-1111-1111-1111-111111111111",
      name: "Local"
    )
    let registry = ServerRuntimeRegistry(
      endpointsProvider: { [endpoint] },
      runtimeFactory: { ServerRuntime(endpoint: $0) },
      shouldBootstrapFromSettings: false
    )
    registry.configureFromSettings(startEnabled: false)

    let store = registry.sessionStore(for: endpoint.id, fallback: SessionStore())
    let session = makeSession(
      id: "session-1",
      endpointId: endpoint.id,
      projectPath: "/repo/project"
    )
    store.sessions = [session]
    store.latestSessionListItems = [makeListItem(from: session)]
    store.setHasReceivedInitialSessionsList(true)

    let router = AppRouter()
    let toastManager = ToastManager()
    let coordinator = WindowSessionCoordinator(
      runtimeRegistry: registry,
      attentionService: AttentionService(),
      notificationManager: NotificationManager(
        isAuthorized: false,
        shouldRequestAuthorizationOnStart: false
      ),
      toastManager: toastManager,
      router: router
    )

    let firstUpdate = Task { () -> RootShellRuntimeUpdate? in
      for await update in coordinator.rootShellRuntime.updates {
        return update
      }
      return nil
    }

    coordinator.start(currentScopedId: session.scopedID)

    let update = try #require(await firstUpdate.value)
    #expect(update.currentSessions.map(\.sessionId) == ["session-1"])
    #expect(coordinator.rootSessions.map(\.sessionId) == ["session-1"])
    #expect(toastManager.currentSessionId == session.scopedID)
    #expect(coordinator.isAnyInitialLoading == false)
  }

  @Test func refreshSessionsFallsBackToDashboardWhenSelectionDisappears() throws {
    let endpoint = try makeEndpoint(
      id: "22222222-2222-2222-2222-222222222222",
      name: "Local"
    )
    let registry = ServerRuntimeRegistry(
      endpointsProvider: { [endpoint] },
      runtimeFactory: { ServerRuntime(endpoint: $0) },
      shouldBootstrapFromSettings: false
    )
    registry.configureFromSettings(startEnabled: false)

    let router = AppRouter()
    let missingRef = SessionRef(endpointId: endpoint.id, sessionId: "missing-session")
    router.selectSession(missingRef)

    let coordinator = WindowSessionCoordinator(
      runtimeRegistry: registry,
      attentionService: AttentionService(),
      notificationManager: NotificationManager(
        isAuthorized: false,
        shouldRequestAuthorizationOnStart: false
      ),
      toastManager: ToastManager(),
      router: router
    )

    coordinator.refreshSessions()

    #expect(router.selectedSessionRef == nil)
    #expect(router.dashboardTab == .missionControl)
  }

  private func makeEndpoint(
    id: String,
    name: String,
    isEnabled: Bool = true,
    isDefault: Bool = true,
    port: Int = 4_000
  ) throws -> ServerEndpoint {
    ServerEndpoint(
      id: try #require(UUID(uuidString: id)),
      name: name,
      wsURL: try #require(URL(string: "ws://127.0.0.1:\(port)/ws")),
      isLocalManaged: true,
      isEnabled: isEnabled,
      isDefault: isDefault
    )
  }

  private func makeSession(
    id: String,
    endpointId: UUID,
    projectPath: String,
    status: Session.SessionStatus = .active,
    workStatus: Session.WorkStatus = .waiting,
    attentionReason: Session.AttentionReason = .none,
    lastActivityAt: Date? = nil
  ) -> Session {
    Session(
      id: id,
      endpointId: endpointId,
      projectPath: projectPath,
      projectName: URL(fileURLWithPath: projectPath).lastPathComponent,
      status: status,
      workStatus: workStatus,
      startedAt: Date(timeIntervalSince1970: 0),
      lastActivityAt: lastActivityAt,
      attentionReason: attentionReason
    )
  }

  private func makeListItem(from session: Session) -> ServerSessionListItem {
    ServerSessionListItem(
      id: session.id,
      provider: .codex,
      projectPath: session.projectPath,
      projectName: session.projectName,
      gitBranch: session.branch,
      model: session.model,
      status: session.status == .active ? .active : .ended,
      workStatus: .waiting,
      codexIntegrationMode: .direct,
      claudeIntegrationMode: nil,
      startedAt: session.startedAt?.ISO8601Format(),
      lastActivityAt: session.lastActivityAt?.ISO8601Format(),
      unreadCount: session.unreadCount,
      pendingToolName: session.pendingToolName,
      repositoryRoot: session.repositoryRoot,
      isWorktree: session.isWorktree,
      worktreeId: session.worktreeId,
      totalTokens: UInt64(session.totalTokens),
      totalCostUSD: session.totalCostUSD,
      displayTitle: session.displayName,
      displayTitleSortKey: session.normalizedDisplayName,
      displaySearchText: session.displaySearchText,
      contextLine: session.summary,
      listStatus: nil,
      effort: session.effort
    )
  }
}
