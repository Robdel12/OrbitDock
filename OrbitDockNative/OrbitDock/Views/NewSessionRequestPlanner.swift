import Foundation

struct NewSessionProviderConfiguration: Equatable, Sendable {
  let provider: SessionProvider
  let claudeModel: String?
  let claudePermissionMode: ClaudePermissionMode
  let allowedToolsText: String
  let disallowedToolsText: String
  let claudeEffort: String?
  let codexModel: String
  let codexAutonomy: AutonomyLevel
}

enum NewSessionLaunchTarget: Equatable, Sendable {
  case direct(cwd: String)
  case worktree(repoPath: String, branch: String, baseBranch: String?)
}

enum NewSessionRequestTemplate: Equatable, Sendable {
  case claude(
    model: String?,
    permissionMode: String?,
    allowedTools: [String],
    disallowedTools: [String],
    effort: String?
  )
  case codex(
    model: String,
    approvalPolicy: String?,
    sandboxMode: String?
  )

  func makeRequest(cwd: String) -> SessionsClient.CreateSessionRequest {
    switch self {
      case let .claude(model, permissionMode, allowedTools, disallowedTools, effort):
        return SessionsClient.CreateSessionRequest(
          provider: "claude",
          cwd: cwd,
          model: model,
          permissionMode: permissionMode,
          allowedTools: allowedTools,
          disallowedTools: disallowedTools,
          effort: effort
        )
      case let .codex(model, approvalPolicy, sandboxMode):
        return SessionsClient.CreateSessionRequest(
          provider: "codex",
          cwd: cwd,
          model: model,
          approvalPolicy: approvalPolicy,
          sandboxMode: sandboxMode
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

    let target: NewSessionLaunchTarget
    if useWorktree, !normalizedBranch.isEmpty {
      target = .worktree(
        repoPath: normalizedPath,
        branch: normalizedBranch,
        baseBranch: normalizedBaseBranch
      )
    } else {
      target = .direct(cwd: normalizedPath)
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
          allowedTools: parseToolList(configuration.allowedToolsText),
          disallowedTools: parseToolList(configuration.disallowedToolsText),
          effort: normalizeOptionalText(configuration.claudeEffort)
        )
      case .codex:
        let normalizedModel = configuration.codexModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModel.isEmpty else { return nil }
        return .codex(
          model: normalizedModel,
          approvalPolicy: configuration.codexAutonomy.approvalPolicy,
          sandboxMode: configuration.codexAutonomy.sandboxMode
        )
    }
  }

  private static func normalizeOptionalText(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
