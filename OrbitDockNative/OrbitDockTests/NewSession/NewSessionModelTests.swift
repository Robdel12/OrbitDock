import Foundation
@testable import OrbitDock
import Testing

struct NewSessionModelTests {
  @Test func canCreateSessionRespectsProviderSpecificGates() throws {
    var model = try NewSessionModel(
      provider: .codex,
      selectedEndpointId: #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
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

  @Test func applyLifecyclePlanProjectsProviderAndWorktreeState() throws {
    var model = try NewSessionModel(
      provider: .claude,
      selectedEndpointId: #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
    )

    let endpointId = try #require(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"))
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
          codexUseOrbitDockOverrides: true,
          selectedAutonomy: .open,
          codexCollaborationMode: .plan,
          codexMultiAgentEnabled: true,
          codexPersonality: .friendly,
          codexServiceTier: .flex,
          codexInstructions: "Keep things calm.",
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
    #expect(model.codexCollaborationMode == .plan)
    #expect(model.codexMultiAgentEnabled == true)
    #expect(model.codexPersonality == .friendly)
    #expect(model.codexServiceTier == .flex)
    #expect(model.codexInstructions == "Keep things calm.")
  }
}
