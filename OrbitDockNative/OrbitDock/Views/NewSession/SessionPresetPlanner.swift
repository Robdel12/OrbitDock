import Foundation

enum SessionPresetPlanner {
  static func capture(name: String, from model: NewSessionModel) -> SessionPreset {
    let configuration: SessionPresetConfiguration
    switch model.provider {
      case .claude:
        configuration = .claude(ClaudePresetConfiguration(
          modelId: model.claudeModelId,
          customModelInput: model.customModelInput,
          useCustomModel: model.useCustomModel,
          permissionMode: model.selectedPermissionMode,
          allowBypassPermissions: model.allowBypassPermissions,
          allowedToolsText: model.allowedToolsText,
          disallowedToolsText: model.disallowedToolsText,
          effort: model.selectedEffort
        ))
      case .codex:
        configuration = .codex(CodexPresetConfiguration(
          model: model.codexModel,
          configMode: model.codexConfigMode,
          configProfile: model.codexConfigProfile,
          modelProvider: model.codexModelProvider,
          autonomy: model.selectedAutonomy,
          collaborationMode: model.codexCollaborationMode,
          multiAgentEnabled: model.codexMultiAgentEnabled,
          personality: model.codexPersonality,
          serviceTier: model.codexServiceTier,
          instructions: model.codexInstructions
        ))
    }

    return SessionPreset(
      id: UUID(),
      name: name,
      provider: model.provider,
      configuration: configuration,
      createdAt: Date()
    )
  }
}
