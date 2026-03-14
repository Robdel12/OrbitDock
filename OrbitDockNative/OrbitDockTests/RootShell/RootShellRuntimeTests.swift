import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct RootShellRuntimeTests {
  @Test func startBootstrapsFromRootSafeSessionListItems() async throws {
    let endpoint = ServerEndpoint(
      id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
      name: "Local",
      wsURL: URL(string: "ws://127.0.0.1:4000/ws")!,
      isLocalManaged: true,
      isEnabled: true,
      isDefault: true
    )

    let clients = ServerClients(serverURL: URL(string: "http://127.0.0.1:4000")!, authToken: nil)
    let eventStream = EventStream(authToken: nil)
    let sessionListItems = [
      ServerSessionListItem(
        id: "session-1",
        provider: .codex,
        projectPath: "/tmp/orbitdock",
        projectName: "OrbitDock",
        gitBranch: "main",
        model: "gpt-5.4",
        status: .active,
        workStatus: .reply,
        codexIntegrationMode: .passive,
        claudeIntegrationMode: nil,
        startedAt: "2026-03-11T01:00:00Z",
        lastActivityAt: "2026-03-11T02:00:00Z",
        unreadCount: 2,
        hasTurnDiff: false,
        pendingToolName: nil,
        repositoryRoot: "/tmp/orbitdock",
        isWorktree: false,
        worktreeId: nil,
        totalTokens: 42,
        totalCostUSD: 0.0,
        displayTitle: "OrbitDock",
        displayTitleSortKey: "orbitdock",
        displaySearchText: "OrbitDock main",
        contextLine: "Context",
        listStatus: nil,
        effort: nil
      )
    ]
    eventStream.seedSessionsListForTesting(sessionListItems)

    let registry = ServerRuntimeRegistry(
      endpointsProvider: { [endpoint] },
      runtimeFactory: { _ in
        ServerRuntime(
          endpoint: endpoint,
          clients: clients,
          eventStream: eventStream
        )
      },
      shouldBootstrapFromSettings: false
    )
    registry.configureFromSettings(startEnabled: false)

    let runtime = RootShellRuntime(runtimeRegistry: registry)
    let update = try await RootShellRuntimeTestSupport.firstUpdate(from: runtime) {
      runtime.start()
    }
    #expect(update.upsertedSessions.map(\.sessionId) == ["session-1"])
    #expect(update.removedScopedIDs.isEmpty)
    #expect(runtime.rootShellStore.records().map(\.sessionId) == ["session-1"])
    #expect(runtime.rootShellStore.records().first?.showsInMissionControl == true)
  }
}
