@testable import OrbitDock
import Testing

struct CodexControlCapabilityTests {
  @Test func collaborationModesFollowAdvertisedModelCapabilities() {
    let option = ServerCodexModelOption(
      id: "gpt-5-codex",
      model: "gpt-5-codex",
      displayName: "GPT-5 Codex",
      description: "Primary coding model.",
      isDefault: true,
      supportedReasoningEfforts: ["low", "medium", "high"],
      supportsReasoningSummaries: true,
      supportedCollaborationModes: ["default"],
      supportsMultiAgent: true,
      multiAgentIsExperimental: true,
      supportsPersonality: true,
      supportedServiceTiers: ["fast", "flex"],
      supportsDeveloperInstructions: true
    )

    #expect(CodexCollaborationMode.supportedCases(from: option) == [.default])
  }

  @Test func serviceTiersKeepAutomaticAndRespectAdvertisedOptions() {
    let option = ServerCodexModelOption(
      id: "gpt-5-codex",
      model: "gpt-5-codex",
      displayName: "GPT-5 Codex",
      description: "Primary coding model.",
      isDefault: true,
      supportedReasoningEfforts: ["low", "medium", "high"],
      supportsReasoningSummaries: true,
      supportedCollaborationModes: ["default", "plan"],
      supportsMultiAgent: true,
      multiAgentIsExperimental: true,
      supportsPersonality: true,
      supportedServiceTiers: ["flex"],
      supportsDeveloperInstructions: true
    )

    #expect(CodexServiceTierPreset.supportedCases(from: option) == [.automatic, .flex])
  }
}
