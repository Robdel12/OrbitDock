import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct WindowRootRuntimeTests {
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

    let runtime = try #require(registry.runtimesByEndpointId[endpoint.id])
    let session = makeSession(
      id: "session-1",
      endpointId: endpoint.id,
      projectPath: "/repo/project"
    )
    runtime.eventStream.seedSessionsListForTesting([makeListItem(from: session)])

    let router = AppRouter()
    let toastManager = ToastManager()
    let rootShellStore = RootShellStore()
    let runtimeCoordinator = RootShellRuntime(
      runtimeRegistry: registry,
      rootShellStore: rootShellStore
    )
    let effects = RootShellEffectsCoordinator(
      rootShellStore: rootShellStore,
      attentionService: AttentionService(),
      notificationManager: NotificationManager(
        isAuthorized: false,
        shouldRequestAuthorizationOnStart: false
      ),
      toastManager: toastManager,
      router: router
    )

    let firstUpdate = Task { () -> RootShellRuntimeUpdate? in
      for await update in runtimeCoordinator.updates {
        return update
      }
      return nil
    }

    effects.setCurrentSelection(session.scopedID)
    runtimeCoordinator.start()

    let update = try #require(await firstUpdate.value)
    effects.applyRootChange(
      previousMissionControlSessions: update.previousMissionControlSessions,
      currentMissionControlSessions: update.currentMissionControlSessions
    )
    #expect(update.currentMissionControlSessions.isEmpty)
    #expect(rootShellStore.records().map(\.sessionId) == ["session-1"])
    #expect(rootShellStore.records().first?.showsInMissionControl == false)
    #expect(toastManager.currentSessionId == session.scopedID)
    #expect(runtime.eventStream.hasReceivedInitialSessionsList)
  }

  @Test func startFallsBackToDashboardWhenSelectionDisappearsFromRootShell() async throws {
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
    let runtime = try #require(registry.runtimesByEndpointId[endpoint.id])

    let router = AppRouter()
    let missingRef = SessionRef(endpointId: endpoint.id, sessionId: "missing-session")
    router.selectSession(missingRef)

    let rootShellStore = RootShellStore()
    let effects = RootShellEffectsCoordinator(
      rootShellStore: rootShellStore,
      attentionService: AttentionService(),
      notificationManager: NotificationManager(
        isAuthorized: false,
        shouldRequestAuthorizationOnStart: false
      ),
      toastManager: ToastManager(),
      router: router
    )

    effects.setCurrentSelection(missingRef.scopedID)
    effects.applyRootChange(
      previousMissionControlSessions: [],
      currentMissionControlSessions: []
    )

    #expect(router.selectedSessionRef == nil)
    #expect(router.dashboardTab == .missionControl)
  }

  @Test func selectedSessionChangesPromoteAndDemoteHotTierMembership() async throws {
    let endpoint = try makeEndpoint(
      id: "33333333-3333-3333-3333-333333333333",
      name: "Local"
    )
    let registry = ServerRuntimeRegistry(
      endpointsProvider: { [endpoint] },
      runtimeFactory: { ServerRuntime(endpoint: $0) },
      shouldBootstrapFromSettings: false
    )
    registry.configureFromSettings(startEnabled: false)

    let coordinator = RootShellRuntime(
      runtimeRegistry: registry,
      rootShellStore: RootShellStore()
    )

    let first = ScopedSessionID(endpointId: endpoint.id, sessionId: "session-a")
    let second = ScopedSessionID(endpointId: endpoint.id, sessionId: "session-b")

    await coordinator.applySelectedSessionChange(to: first.scopedID)
    #expect(await coordinator.hotSessionIDsForTesting() == [first.scopedID])

    await coordinator.applySelectedSessionChange(to: second.scopedID)
    #expect(await coordinator.hotSessionIDsForTesting() == [second.scopedID])

    await coordinator.applySelectedSessionChange(to: nil)
    #expect(await coordinator.hotSessionIDsForTesting().isEmpty)
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
      hasTurnDiff: false,
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
