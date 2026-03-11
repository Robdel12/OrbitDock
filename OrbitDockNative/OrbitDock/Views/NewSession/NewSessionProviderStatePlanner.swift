import Foundation

struct NewSessionProviderState: Equatable {
  var claudeModelId: String
  var customModelInput: String
  var useCustomModel: Bool
  var selectedPermissionMode: ClaudePermissionMode
  var allowedToolsText: String
  var disallowedToolsText: String
  var showToolConfig: Bool
  var selectedEffort: ClaudeEffortLevel
  var codexModel: String
  var selectedAutonomy: AutonomyLevel
  var codexCollaborationMode: CodexCollaborationMode
  var codexMultiAgentEnabled: Bool
  var codexPersonality: CodexPersonalityPreset
  var codexServiceTier: CodexServiceTierPreset
  var codexInstructions: String
  var codexErrorMessage: String?

  static let `default` = NewSessionProviderState(
    claudeModelId: "",
    customModelInput: "",
    useCustomModel: false,
    selectedPermissionMode: .default,
    allowedToolsText: "",
    disallowedToolsText: "",
    showToolConfig: false,
    selectedEffort: .default,
    codexModel: "",
    selectedAutonomy: .autonomous,
    codexCollaborationMode: .default,
    codexMultiAgentEnabled: false,
    codexPersonality: .automatic,
    codexServiceTier: .automatic,
    codexInstructions: "",
    codexErrorMessage: nil
  )
}

struct NewSessionClaudeModelSelection: Equatable {
  let modelId: String
  let useCustomModel: Bool
}

enum NewSessionProviderStatePlanner {
  static func reset() -> NewSessionProviderState {
    .default
  }

  static func syncClaudeModelSelection(
    currentModelId: String,
    useCustomModel: Bool,
    models: [ServerClaudeModelOption]
  ) -> NewSessionClaudeModelSelection {
    if models.isEmpty {
      return NewSessionClaudeModelSelection(modelId: "", useCustomModel: true)
    }

    if !currentModelId.isEmpty, models.contains(where: { $0.value == currentModelId }) {
      return NewSessionClaudeModelSelection(modelId: currentModelId, useCustomModel: useCustomModel)
    }

    return NewSessionClaudeModelSelection(
      modelId: models.first?.value ?? "",
      useCustomModel: false
    )
  }

  static func syncCodexModelSelection(
    currentModel: String,
    models: [ServerCodexModelOption]
  ) -> String {
    if !currentModel.isEmpty, models.contains(where: { $0.model == currentModel }) {
      return currentModel
    }

    if let model = models.first(where: { $0.isDefault && !$0.model.isEmpty })?.model {
      return model
    }

    return models.first(where: { !$0.model.isEmpty })?.model ?? ""
  }
}
