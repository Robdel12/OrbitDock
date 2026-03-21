import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct NewSessionLifecyclePlannerTests {
  @Test func onAppearPrefersContinuationEndpointAndSeedsContinuationDefaults() throws {
    let primaryEndpointId = try #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
    let continuationEndpointId = try #require(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"))
    let plan = NewSessionLifecyclePlanner.onAppear(
      current: makeState(selectedEndpointId: primaryEndpointId),
      selectableEndpoints: [
        makeEndpoint(id: primaryEndpointId, isDefault: true),
        makeEndpoint(id: continuationEndpointId),
      ],
      primaryEndpointId: primaryEndpointId,
      continuationEndpointId: continuationEndpointId,
      continuationDefaults: NewSessionContinuationDefaults(
        projectPath: "/tmp/printer",
        hasGitRepository: true
      )
    )

    #expect(plan.nextState.selectedEndpointId == continuationEndpointId)
    #expect(plan.nextState.selectedPath == "/tmp/printer")
    #expect(plan.nextState.selectedPathIsGit == true)
    #expect(plan.shouldRefreshEndpointData == true)
    #expect(plan.shouldSyncModelSelections == true)
  }

  @Test func endpointChangedResetsStateAndReappliesContinuationDefaultsForMatchingEndpoint() throws {
    let endpointId = try #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
    let state = NewSessionLifecycleState(
      selectedEndpointId: endpointId,
      selectedPath: "/tmp/old",
      selectedPathIsGit: false,
      providerState: NewSessionProviderState(
        claudeModelId: "claude-opus",
        customModelInput: "custom",
        useCustomModel: true,
        selectedPermissionMode: .acceptEdits,
        allowedToolsText: "Read",
        disallowedToolsText: "Write",
        showToolConfig: true,
        selectedEffort: .high,
        codexModel: "gpt-5-codex",
        codexConfigMode: .custom,
        codexConfigProfile: "qwen",
        codexModelProvider: "openrouter",
        selectedAutonomy: .fullAuto,
        codexCollaborationMode: .plan,
        codexMultiAgentEnabled: true,
        codexPersonality: .friendly,
        codexServiceTier: .fast,
        codexInstructions: "Stay tidy.",
        codexErrorMessage: "oops"
      ),
      worktreeState: NewSessionWorktreeState(
        useWorktree: true,
        branch: "feature/test",
        baseBranch: "main",
        error: "bad branch"
      )
    )

    let plan = NewSessionLifecyclePlanner.endpointChanged(
      current: state,
      requestedEndpointId: endpointId,
      selectableEndpoints: [makeEndpoint(id: endpointId, isDefault: true)],
      primaryEndpointId: endpointId,
      continuationEndpointId: endpointId,
      continuationDefaults: NewSessionContinuationDefaults(
        projectPath: "/tmp/new",
        hasGitRepository: false
      )
    )

    #expect(plan.nextState.selectedPath == "/tmp/new")
    #expect(plan.nextState.selectedPathIsGit == false)
    #expect(plan.nextState.providerState == .default)
    #expect(plan.nextState.worktreeState == .default)
    #expect(plan.shouldRefreshEndpointData == true)
    #expect(plan.shouldSyncModelSelections == false)
  }

  @Test func pathChangedClearsWorktreeStateWithoutRefreshingModels() throws {
    let endpointId = try #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
    let plan = NewSessionLifecyclePlanner.pathChanged(
      current: NewSessionLifecycleState(
        selectedEndpointId: endpointId,
        selectedPath: "/tmp/old",
        selectedPathIsGit: true,
        providerState: .default,
        worktreeState: NewSessionWorktreeState(
          useWorktree: true,
          branch: "feature/test",
          baseBranch: "main",
          error: "bad branch"
        )
      ),
      newPath: "/tmp/new"
    )

    #expect(plan.nextState.selectedPath == "/tmp/new")
    #expect(plan.nextState.worktreeState == .default)
    #expect(plan.shouldRefreshEndpointData == false)
    #expect(plan.shouldSyncModelSelections == false)
  }

  @Test func providerChangedResetsOnlyProviderState() throws {
    let endpointId = try #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
    let current = NewSessionLifecycleState(
      selectedEndpointId: endpointId,
      selectedPath: "/tmp/project",
      selectedPathIsGit: true,
      providerState: NewSessionProviderState(
        claudeModelId: "claude-opus",
        customModelInput: "",
        useCustomModel: false,
        selectedPermissionMode: .bypassPermissions,
        allowedToolsText: "Read",
        disallowedToolsText: "",
        showToolConfig: true,
        selectedEffort: .medium,
        codexModel: "gpt-5-codex",
        codexConfigMode: .custom,
        codexConfigProfile: "qwen",
        codexModelProvider: "openrouter",
        selectedAutonomy: .fullAuto,
        codexCollaborationMode: .plan,
        codexMultiAgentEnabled: true,
        codexPersonality: .pragmatic,
        codexServiceTier: .flex,
        codexInstructions: "Be concise.",
        codexErrorMessage: "bad"
      ),
      worktreeState: NewSessionWorktreeState(
        useWorktree: true,
        branch: "feature/test",
        baseBranch: "",
        error: nil
      )
    )

    let plan = NewSessionLifecyclePlanner.providerChanged(current: current)

    #expect(plan.nextState.selectedPath == current.selectedPath)
    #expect(plan.nextState.worktreeState == current.worktreeState)
    #expect(plan.nextState.providerState == .default)
    #expect(plan.shouldRefreshEndpointData == true)
    #expect(plan.shouldSyncModelSelections == true)
  }

  private func makeState(selectedEndpointId: UUID) -> NewSessionLifecycleState {
    NewSessionLifecycleState(
      selectedEndpointId: selectedEndpointId,
      selectedPath: "",
      selectedPathIsGit: true,
      providerState: .default,
      worktreeState: .default
    )
  }

  private func makeEndpoint(id: UUID, isDefault: Bool = false) -> ServerEndpoint {
    ServerEndpoint(
      id: id,
      name: isDefault ? "Default" : "Remote",
      wsURL: URL(string: "ws://127.0.0.1:4000/ws")!,
      isLocalManaged: true,
      isEnabled: true,
      isDefault: isDefault
    )
  }
}
