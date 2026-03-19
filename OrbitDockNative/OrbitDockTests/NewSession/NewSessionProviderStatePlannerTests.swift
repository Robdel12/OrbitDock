@testable import OrbitDock
import Testing

@MainActor
struct NewSessionProviderStatePlannerTests {
  @Test func resetReturnsDefaultProviderState() {
    let state = NewSessionProviderStatePlanner.reset()

    #expect(state.claudeModelId.isEmpty)
    #expect(state.customModelInput.isEmpty)
    #expect(state.useCustomModel == false)
    #expect(state.selectedPermissionMode == .default)
    #expect(state.allowedToolsText.isEmpty)
    #expect(state.disallowedToolsText.isEmpty)
    #expect(state.showToolConfig == false)
    #expect(state.selectedEffort == .default)
    #expect(state.codexModel.isEmpty)
    #expect(state.codexUseOrbitDockOverrides == false)
    #expect(state.selectedAutonomy == .autonomous)
    #expect(state.codexCollaborationMode == .default)
    #expect(state.codexMultiAgentEnabled == false)
    #expect(state.codexPersonality == .automatic)
    #expect(state.codexServiceTier == .automatic)
    #expect(state.codexInstructions.isEmpty)
    #expect(state.codexErrorMessage == nil)
  }

  @Test func claudeModelSelectionFallsBackToCustomWhenNoModelsExist() {
    let selection = NewSessionProviderStatePlanner.syncClaudeModelSelection(
      currentModelId: "claude-opus",
      useCustomModel: false,
      models: []
    )

    #expect(selection.modelId.isEmpty)
    #expect(selection.useCustomModel == true)
  }

  @Test func claudeModelSelectionKeepsValidCurrentModel() {
    let models = [
      ServerClaudeModelOption(value: "claude-opus", displayName: "Claude Opus", description: "Best"),
      ServerClaudeModelOption(value: "claude-sonnet", displayName: "Claude Sonnet", description: "Fast"),
    ]

    let selection = NewSessionProviderStatePlanner.syncClaudeModelSelection(
      currentModelId: "claude-sonnet",
      useCustomModel: true,
      models: models
    )

    #expect(selection.modelId == "claude-sonnet")
    #expect(selection.useCustomModel == true)
  }

  @Test func codexModelSelectionPrefersDefaultThenFirstAvailable() {
    let models = [
      ServerCodexModelOption(
        id: "mini",
        model: "gpt-5-codex-mini",
        displayName: "Mini",
        description: "Fast",
        isDefault: false,
        supportedReasoningEfforts: []
      ),
      ServerCodexModelOption(
        id: "default",
        model: "gpt-5-codex",
        displayName: "Default",
        description: "Balanced",
        isDefault: true,
        supportedReasoningEfforts: []
      ),
    ]

    #expect(
      NewSessionProviderStatePlanner.syncCodexModelSelection(
        currentModel: "",
        shouldPreferDefaultModel: true,
        models: models
      ) == "gpt-5-codex"
    )

    #expect(
      NewSessionProviderStatePlanner.syncCodexModelSelection(
        currentModel: "gpt-5-codex-mini",
        shouldPreferDefaultModel: true,
        models: models
      ) == "gpt-5-codex-mini"
    )
  }
}
