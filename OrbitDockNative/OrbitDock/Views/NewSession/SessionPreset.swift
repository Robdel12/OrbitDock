import Foundation

struct SessionPreset: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  var name: String
  let provider: SessionProvider
  let configuration: SessionPresetConfiguration
  let createdAt: Date
}

enum SessionPresetConfiguration: Codable, Equatable, Sendable {
  case claude(ClaudePresetConfiguration)
  case codex(CodexPresetConfiguration)
}

struct ClaudePresetConfiguration: Codable, Equatable, Sendable {
  let modelId: String
  let customModelInput: String
  let useCustomModel: Bool
  let permissionMode: ClaudePermissionMode
  let allowBypassPermissions: Bool
  let allowedToolsText: String
  let disallowedToolsText: String
  let effort: ClaudeEffortLevel

  var summary: String {
    let model = useCustomModel ? (customModelInput.isEmpty ? "Default" : customModelInput) : (modelId.isEmpty ? "Default" : modelId)
    var parts = [model, permissionMode.displayName]
    if effort != .default {
      parts.append(effort.displayName)
    }
    return parts.joined(separator: " · ")
  }
}

struct CodexPresetConfiguration: Codable, Equatable, Sendable {
  let model: String
  let configMode: ServerCodexConfigMode
  let configProfile: String
  let modelProvider: String
  let autonomy: AutonomyLevel
  let collaborationMode: CodexCollaborationMode
  let multiAgentEnabled: Bool
  let personality: CodexPersonalityPreset
  let serviceTier: CodexServiceTierPreset
  let instructions: String

  var summary: String {
    switch configMode {
      case .inherit:
        return "Inherited config · \(autonomy.displayName)"
      case .profile:
        let name = configProfile.isEmpty ? "Saved profile" : configProfile
        return "\(name) · \(autonomy.displayName)"
      case .custom:
        let modelName = model.isEmpty ? "Default" : model
        return "\(modelName) · \(autonomy.displayName)"
    }
  }
}
