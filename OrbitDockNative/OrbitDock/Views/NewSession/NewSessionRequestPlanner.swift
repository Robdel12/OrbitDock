import Foundation

struct NewSessionProviderConfiguration: Equatable, Sendable {
  let provider: SessionProvider
  let claudeModel: String?
  let claudePermissionMode: ClaudePermissionMode
  let claudeAllowBypassPermissions: Bool
  let allowedToolsText: String
  let disallowedToolsText: String
  let claudeEffort: String?
  let codexModel: String
  let codexConfigMode: ServerCodexConfigMode
  let codexConfigProfile: String
  let codexModelProvider: String
  let codexAutonomy: AutonomyLevel
  let codexCollaborationMode: String?
  let codexMultiAgentEnabled: Bool
  let codexPersonality: String?
  let codexServiceTier: String?
  let codexInstructions: String?
}

enum NewSessionLaunchTarget: Equatable, Sendable {
  case direct(cwd: String)
  case worktree(repoPath: String, branch: String, baseBranch: String?)
}

enum NewSessionRequestTemplate: Equatable, Sendable {
  case claude(
    model: String?,
    permissionMode: String?,
    allowBypassPermissions: Bool,
    allowedTools: [String],
    disallowedTools: [String],
    effort: String?
  )
  case codex(
    configMode: ServerCodexConfigMode,
    configProfile: String?,
    modelProvider: String?,
    model: String?,
    approvalPolicy: String?,
    sandboxMode: String?,
    collaborationMode: String?,
    multiAgent: Bool?,
    personality: String?,
    serviceTier: String?,
    developerInstructions: String?
  )

  func makeRequest(cwd: String) -> SessionsClient.CreateSessionRequest {
    switch self {
      case let .claude(model, permissionMode, allowBypassPermissions, allowedTools, disallowedTools, effort):
        SessionsClient.CreateSessionRequest(
          provider: "claude",
          cwd: cwd,
          model: model,
          permissionMode: permissionMode,
          allowedTools: allowedTools,
          disallowedTools: disallowedTools,
          effort: effort,
          allowBypassPermissions: allowBypassPermissions ? true : nil
        )
      case let .codex(
      configMode,
      configProfile,
      modelProvider,
      model,
      approvalPolicy,
      sandboxMode,
      collaborationMode,
      multiAgent,
      personality,
      serviceTier,
      developerInstructions
    ):
        SessionsClient.CreateSessionRequest(
          provider: "codex",
          cwd: cwd,
          model: model,
          modelProvider: modelProvider,
          approvalPolicy: approvalPolicy,
          sandboxMode: sandboxMode,
          collaborationMode: collaborationMode,
          multiAgent: multiAgent,
          personality: personality,
          serviceTier: serviceTier,
          developerInstructions: developerInstructions,
          codexConfigSource: .user,
          codexConfigMode: configMode,
          codexConfigProfile: configProfile
        )
    }
  }
}

struct NewSessionLaunchPlan: Equatable, Sendable {
  let target: NewSessionLaunchTarget
  let requestTemplate: NewSessionRequestTemplate
  let bootstrapPrompt: String?
}

enum NewSessionRequestPlanner {
  static func planLaunch(
    selectedPath: String,
    useWorktree: Bool,
    worktreeBranch: String,
    worktreeBaseBranch: String,
    providerConfiguration: NewSessionProviderConfiguration,
    bootstrapPrompt: String?
  ) -> NewSessionLaunchPlan? {
    let normalizedPath = selectedPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedPath.isEmpty else { return nil }

    guard let requestTemplate = requestTemplate(for: providerConfiguration) else { return nil }
    let normalizedBranch = worktreeBranch.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedBaseBranch = normalizeOptionalText(worktreeBaseBranch)

    let target: NewSessionLaunchTarget = if useWorktree, !normalizedBranch.isEmpty {
      .worktree(
        repoPath: normalizedPath,
        branch: normalizedBranch,
        baseBranch: normalizedBaseBranch
      )
    } else {
      .direct(cwd: normalizedPath)
    }

    return NewSessionLaunchPlan(
      target: target,
      requestTemplate: requestTemplate,
      bootstrapPrompt: normalizeOptionalText(bootstrapPrompt)
    )
  }

  static func parseToolList(_ text: String) -> [String] {
    text.split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private static func requestTemplate(
    for configuration: NewSessionProviderConfiguration
  ) -> NewSessionRequestTemplate? {
    switch configuration.provider {
      case .claude:
        return .claude(
          model: normalizeOptionalText(configuration.claudeModel),
          permissionMode: configuration.claudePermissionMode == .default
            ? nil
            : configuration.claudePermissionMode.rawValue,
          allowBypassPermissions: configuration.claudeAllowBypassPermissions,
          allowedTools: parseToolList(configuration.allowedToolsText),
          disallowedTools: parseToolList(configuration.disallowedToolsText),
          effort: normalizeOptionalText(configuration.claudeEffort)
        )
      case .codex:
        let normalizedModel = configuration.codexModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedProfile = configuration.codexConfigMode == .profile
          ? normalizeOptionalText(configuration.codexConfigProfile)
          : nil
        let normalizedModelProvider = configuration.codexConfigMode == .custom
          ? normalizeOptionalText(configuration.codexModelProvider)
          : nil
        let shouldApplyOverrides = configuration.codexConfigMode == .custom

        if configuration.codexConfigMode == .profile, normalizedProfile == nil {
          return nil
        }

        if shouldApplyOverrides, normalizedModel.isEmpty || normalizedModelProvider == nil {
          return nil
        }
        return .codex(
          configMode: configuration.codexConfigMode,
          configProfile: normalizedProfile,
          modelProvider: shouldApplyOverrides ? normalizedModelProvider : nil,
          model: shouldApplyOverrides ? normalizedModel : nil,
          approvalPolicy: shouldApplyOverrides ? configuration.codexAutonomy.approvalPolicy : nil,
          sandboxMode: shouldApplyOverrides ? configuration.codexAutonomy.sandboxMode : nil,
          collaborationMode: shouldApplyOverrides
            ? normalizeOptionalText(configuration.codexCollaborationMode)
            : nil,
          multiAgent: shouldApplyOverrides ? configuration.codexMultiAgentEnabled : nil,
          personality: shouldApplyOverrides ? normalizeOptionalText(configuration.codexPersonality) : nil,
          serviceTier: shouldApplyOverrides ? normalizeOptionalText(configuration.codexServiceTier) : nil,
          developerInstructions: shouldApplyOverrides
            ? normalizeOptionalText(configuration.codexInstructions)
            : nil
        )
    }
  }

  private static func normalizeOptionalText(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
