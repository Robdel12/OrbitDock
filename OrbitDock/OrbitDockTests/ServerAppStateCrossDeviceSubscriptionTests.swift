import Foundation
@testable import OrbitDock
import Testing

struct ServerAppStateCrossDeviceSubscriptionTests {
  @MainActor
  @Test func remoteSessionCreatedDoesNotAutoSubscribe() async {
    let state = ServerAppState()
    state.setup()
    let sessionId = "remote-created-session"

    state.connection.onSessionCreated?(makeSessionSummary(id: sessionId))
    await Task.yield()

    #expect(state.sessions.contains(where: { $0.id == sessionId }))
    #expect(!state.isSessionSubscribed(sessionId))
  }

  @MainActor
  @Test func localCreateWorkflowAutoSubscribesCreatedSession() async {
    let state = ServerAppState()
    state.setup()
    let sessionId = "locally-created-session"

    state.createSession(cwd: "/tmp/project")
    state.connection.onSessionCreated?(makeSessionSummary(id: sessionId))
    await Task.yield()

    #expect(state.isSessionSubscribed(sessionId))
  }

  private func makeSessionSummary(id: String) -> ServerSessionSummary {
    ServerSessionSummary(
      id: id,
      provider: .codex,
      projectPath: "/tmp/project",
      transcriptPath: nil,
      projectName: nil,
      model: nil,
      customName: nil,
      summary: nil,
      status: .active,
      workStatus: .working,
      tokenUsage: nil,
      tokenUsageSnapshotKind: nil,
      hasPendingApproval: false,
      codexIntegrationMode: nil,
      claudeIntegrationMode: nil,
      approvalPolicy: nil,
      sandboxMode: nil,
      permissionMode: nil,
      pendingToolName: nil,
      pendingToolInput: nil,
      pendingQuestion: nil,
      pendingApprovalId: nil,
      startedAt: "2026-03-08T00:00:00Z",
      lastActivityAt: "2026-03-08T00:00:00Z",
      gitBranch: nil,
      gitSha: nil,
      currentCwd: nil,
      firstPrompt: nil,
      lastMessage: nil,
      effort: nil,
      approvalVersion: nil,
      repositoryRoot: nil,
      isWorktree: nil,
      worktreeId: nil,
      unreadCount: nil
    )
  }
}
