@testable import OrbitDock
import Foundation
import Testing

struct NewSessionModelTests {
  @Test func canCreateSessionRespectsProviderSpecificGates() {
    var model = NewSessionModel(
      provider: .codex,
      selectedEndpointId: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    )
    model.selectedPath = "/tmp/printer"
    model.codexModel = "gpt-5-codex"

    #expect(
      !model.canCreateSession(
        isEndpointConnected: true,
        requiresCodexLogin: true,
        continuationSupported: true
      )
    )

    #expect(
      model.canCreateSession(
        isEndpointConnected: true,
        requiresCodexLogin: false,
        continuationSupported: true
      )
    )

    model.provider = .claude
    model.codexModel = ""

    #expect(
      model.canCreateSession(
        isEndpointConnected: true,
        requiresCodexLogin: false,
        continuationSupported: true
      )
    )
  }

  @Test func applyLifecyclePlanProjectsProviderAndWorktreeState() {
    var model = NewSessionModel(
      provider: .claude,
      selectedEndpointId: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    )

    let endpointId = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    let plan = NewSessionLifecyclePlan(
      nextState: NewSessionLifecycleState(
        selectedEndpointId: endpointId,
        selectedPath: "/tmp/printer",
        selectedPathIsGit: false,
        providerState: NewSessionProviderState(
          claudeModelId: "claude-opus",
          customModelInput: "custom",
          useCustomModel: true,
          selectedPermissionMode: .acceptEdits,
          allowedToolsText: "Read,Glob",
          disallowedToolsText: "Write",
          showToolConfig: true,
          selectedEffort: .high,
          codexModel: "gpt-5-codex",
          selectedAutonomy: .open,
          codexErrorMessage: "oops"
        ),
        worktreeState: NewSessionWorktreeState(
          useWorktree: true,
          branch: "feature/printer",
          baseBranch: "main",
          error: "bad branch"
        )
      ),
      shouldRefreshEndpointData: true,
      shouldSyncModelSelections: false
    )

    model.applyLifecyclePlan(plan)

    #expect(model.selectedEndpointId == endpointId)
    #expect(model.selectedPath == "/tmp/printer")
    #expect(model.selectedPathIsGit == false)
    #expect(model.useCustomModel == true)
    #expect(model.claudeModelId == "claude-opus")
    #expect(model.worktreeBranch == "feature/printer")
    #expect(model.worktreeBaseBranch == "main")
    #expect(model.worktreeError == "bad branch")
  }
}
