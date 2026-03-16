@testable import OrbitDock
import Testing

struct DirectSessionComposerProviderPlannerTests {
  @Test func codexDefaultModelPrefersCurrentWhenAvailable() {
    let options = [
      ServerCodexModelOption(
        id: "o4",
        model: "openai/o4-mini",
        displayName: "o4-mini",
        description: "Default",
        isDefault: true,
        supportedReasoningEfforts: ["low", "medium"]
      ),
      ServerCodexModelOption(
        id: "o3",
        model: "openai/o3",
        displayName: "o3",
        description: "Reasoning",
        isDefault: false,
        supportedReasoningEfforts: ["high"]
      ),
    ]

    let selection = DirectSessionComposerProviderPlanner.defaultCodexModelSelection(
      currentModel: "openai/o3",
      options: options
    )

    #expect(selection == "openai/o3")
  }

  @Test func effectiveClaudeModelFallsBackFromOverrideToSessionToDefault() {
    let options = [
      ServerClaudeModelOption(
        value: "claude-opus-4-1",
        displayName: "Opus",
        description: "Big model"
      ),
    ]

    #expect(
      DirectSessionComposerProviderPlanner.effectiveClaudeModel(
        selectedClaudeModel: "claude-sonnet-4",
        sessionModel: "claude-opus-4-1",
        options: options
      ) == "claude-sonnet-4"
    )
    #expect(
      DirectSessionComposerProviderPlanner.effectiveClaudeModel(
        selectedClaudeModel: "",
        sessionModel: "claude-opus-4-1",
        options: options
      ) == "claude-opus-4-1"
    )
    #expect(
      DirectSessionComposerProviderPlanner.effectiveClaudeModel(
        selectedClaudeModel: "",
        sessionModel: nil,
        options: options
      ) == "claude-opus-4-1"
    )
  }

  @Test func hasOverridesTracksProviderSpecificSelections() {
    let codexOptions = [
      ServerCodexModelOption(
        id: "o4",
        model: "openai/o4-mini",
        displayName: "o4-mini",
        description: "Default",
        isDefault: true,
        supportedReasoningEfforts: ["low", "medium"]
      ),
    ]
    let claudeOptions = [
      ServerClaudeModelOption(
        value: "claude-opus-4-1",
        displayName: "Opus",
        description: "Big model"
      ),
    ]

    #expect(
      !DirectSessionComposerProviderPlanner.hasOverrides(
        providerMode: .directCodex,
        selectedCodexModel: "openai/o4-mini",
        selectedClaudeModel: "",
        currentModel: nil,
        selectedEffort: .default,
        codexOptions: codexOptions,
        claudeOptions: claudeOptions
      )
    )

    #expect(
      DirectSessionComposerProviderPlanner.hasOverrides(
        providerMode: .directCodex,
        selectedCodexModel: "openai/o4-mini",
        selectedClaudeModel: "",
        currentModel: nil,
        selectedEffort: .high,
        codexOptions: codexOptions,
        claudeOptions: claudeOptions
      )
    )

    #expect(
      DirectSessionComposerProviderPlanner.hasOverrides(
        providerMode: .directClaude,
        selectedCodexModel: "",
        selectedClaudeModel: "claude-sonnet-4",
        currentModel: nil,
        selectedEffort: .default,
        codexOptions: codexOptions,
        claudeOptions: claudeOptions
      )
    )
  }

  @Test func compactModelNameStripsPrefixesAndLongSuffixes() {
    #expect(DirectSessionComposerProviderPlanner.compactModelName("openai/o3") == "o3")
    #expect(
      DirectSessionComposerProviderPlanner.compactModelName("anthropic/claude-opus-4-1")
        == "claude-opus"
    )
  }
}
