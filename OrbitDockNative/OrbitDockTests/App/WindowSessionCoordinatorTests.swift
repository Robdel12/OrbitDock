import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct WindowSessionCoordinatorTests {
  @Test func startRefreshesSessionProjectionAndTracksCurrentSelection() throws {
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

    coordinator.start(currentScopedId: session.scopedID)

    #expect(coordinator.sessions.map { $0.id } == ["session-1"])
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
}
