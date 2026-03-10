import Foundation
@testable import OrbitDock
import Testing

struct SessionSemanticsTests {
  @Test func displayNamePrefersMeaningfulSessionContext() {
    let named = Session(
      id: "named",
      projectPath: "/tmp/project",
      projectName: "Project",
      summary: "Summary",
      customName: " Custom Name ",
      firstPrompt: "Prompt",
      status: .active,
      workStatus: .working
    )
    let promptFallback = Session(
      id: "prompt",
      projectPath: "/tmp/project",
      firstPrompt: " <b>Ship it</b> ",
      status: .active,
      workStatus: .working
    )

    #expect(named.displayName == "Custom Name")
    #expect(promptFallback.displayName == "Ship it")
  }

  @Test func groupingPathPrefersRepositoryRoot() {
    let grouped = Session(
      id: "grouped",
      projectPath: "/tmp/worktree",
      status: .active,
      workStatus: .working
    )
    var repoRootSession = grouped
    repoRootSession.repositoryRoot = "/tmp/repo"

    #expect(grouped.groupingPath == "/tmp/worktree")
    #expect(repoRootSession.groupingPath == "/tmp/repo")
  }

  @Test func missionControlAndAttentionStateFollowPureSemantics() {
    let activeConnected = Session(
      id: "active",
      endpointConnectionStatus: .connected,
      projectPath: "/tmp/project",
      status: .active,
      workStatus: .working,
      attentionReason: .awaitingPermission
    )
    let disconnected = Session(
      id: "disconnected",
      endpointConnectionStatus: .disconnected,
      projectPath: "/tmp/project",
      status: .active,
      workStatus: .working,
      attentionReason: .awaitingPermission
    )
    let ready = Session(
      id: "ready",
      endpointConnectionStatus: .connected,
      projectPath: "/tmp/project",
      status: .active,
      workStatus: .waiting,
      attentionReason: .awaitingReply
    )

    #expect(activeConnected.showsInMissionControl)
    #expect(activeConnected.needsAttention)
    #expect(!activeConnected.isReady)

    #expect(!disconnected.showsInMissionControl)
    #expect(disconnected.needsAttention)

    #expect(ready.showsInMissionControl)
    #expect(!ready.needsAttention)
    #expect(ready.isReady)
  }
}
