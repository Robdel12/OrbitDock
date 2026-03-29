import Foundation

nonisolated enum ControlDeckSnapshotMapper {
  static func map(_ payload: ServerControlDeckSnapshotPayload) -> ControlDeckSnapshot {
    ControlDeckSnapshot(
      revision: payload.revision,
      sessionId: payload.sessionId,
      state: mapState(payload.state),
      capabilities: mapCapabilities(payload.capabilities),
      preferences: mapPreferences(payload.preferences),
      tokenUsage: mapTokenUsage(payload.tokenUsage),
      tokenUsageSnapshotKind: mapSnapshotKind(payload.tokenUsageSnapshotKind),
      tokenStatus: mapTokenStatus(payload.tokenStatus)
    )
  }

  static func mapState(_ state: ServerControlDeckState) -> ControlDeckSessionState {
    ControlDeckSessionState(
      provider: mapProvider(state.provider),
      controlMode: mapControlMode(state.controlMode),
      lifecycle: mapLifecycle(state.lifecycleState),
      acceptsUserInput: state.acceptsUserInput,
      steerable: state.steerable,
      projectPath: state.projectPath,
      currentCwd: state.currentCwd,
      gitBranch: state.gitBranch,
      config: mapConfig(state.config)
    )
  }

  static func mapCapabilities(_ caps: ServerControlDeckCapabilities) -> ControlDeckCapabilities {
    ControlDeckCapabilities(
      supportsSkills: caps.supportsSkills,
      supportsMentions: caps.supportsMentions,
      supportsImages: caps.supportsImages,
      supportsSteer: caps.supportsSteer,
      allowPerTurnModelOverride: caps.allowPerTurnModelOverride,
      allowPerTurnEffortOverride: caps.allowPerTurnEffortOverride,
      approvalModeOptions: caps.approvalModeOptions.map(mapPickerOption),
      permissionModeOptions: caps.permissionModeOptions.map(mapPickerOption),
      collaborationModeOptions: caps.collaborationModeOptions.map(mapPickerOption),
      autoReviewOptions: caps.autoReviewOptions.map(mapAutoReviewOption),
      availableStatusModules: caps.availableStatusModules.compactMap(mapModule)
    )
  }

  static func mapPreferences(_ prefs: ServerControlDeckPreferences) -> ControlDeckPreferences {
    ControlDeckPreferences(
      density: mapDensity(prefs.density),
      showWhenEmpty: mapEmptyVisibility(prefs.showWhenEmpty),
      modules: prefs.modules.compactMap { pref in
        guard let module = mapModule(pref.module) else { return nil }
        return ControlDeckModulePreference(module: module, visible: pref.visible)
      }
    )
  }

  static func mapSkill(_ skill: ServerSkillMetadata) -> ControlDeckSkill {
    ControlDeckSkill(
      name: skill.name,
      path: skill.path,
      description: skill.description,
      shortDescription: skill.shortDescription
    )
  }

  // MARK: - Private

  private static func mapProvider(_ provider: ServerProvider) -> ControlDeckProvider {
    switch provider {
      case .claude: .claude
      case .codex: .codex
    }
  }

  private static func mapControlMode(_ mode: ServerSessionControlMode) -> ControlDeckControlMode {
    switch mode {
      case .direct: .direct
      case .passive: .passive
    }
  }

  private static func mapLifecycle(_ state: ServerSessionLifecycleState) -> ControlDeckLifecycle {
    switch state {
      case .open: .open
      case .resumable: .resumable
      case .ended: .ended
    }
  }

  private static func mapConfig(_ config: ServerControlDeckConfigState) -> ControlDeckConfig {
    ControlDeckConfig(
      model: config.model,
      effort: config.effort,
      approvalPolicy: config.approvalPolicy,
      approvalPolicyDetails: config.approvalPolicyDetails,
      sandboxMode: config.sandboxMode,
      approvalsReviewer: config.approvalsReviewer,
      permissionMode: config.permissionMode,
      collaborationMode: config.collaborationMode
    )
  }

  private static func mapModule(_ module: ServerControlDeckModule) -> ControlDeckStatusModule? {
    switch module {
      case .connection: nil // App-level concern, not a session module
      case .autonomy: .autonomy
      case .approvalMode: .approvalMode
      case .collaborationMode: .collaborationMode
      case .autoReview: .autoReview
      case .tokens: .tokens
      case .model: .model
      case .effort: .effort
      case .branch: .branch
      case .cwd: .cwd
      case .attachments: nil // The deck already renders real attachments inline
    }
  }

  private static func mapDensity(_ density: ServerControlDeckDensity) -> ControlDeckDensity {
    switch density {
      case .comfortable: .comfortable
      case .compact: .compact
    }
  }

  private static func mapEmptyVisibility(_ vis: ServerControlDeckEmptyVisibility) -> ControlDeckEmptyVisibility {
    switch vis {
      case .auto: .auto
      case .always: .always
      case .hidden: .hidden
    }
  }

  static func mapTokenUsage(_ usage: ServerTokenUsage) -> ControlDeckTokenUsage {
    ControlDeckTokenUsage(
      inputTokens: usage.inputTokens,
      outputTokens: usage.outputTokens,
      cachedTokens: usage.cachedTokens,
      contextWindow: usage.contextWindow
    )
  }

  static func mapTokenStatus(_ status: ServerControlDeckTokenStatus) -> ControlDeckTokenStatus {
    ControlDeckTokenStatus(
      label: status.label,
      tone: mapTokenTone(status.tone)
    )
  }

  // MARK: - Approval Mapping

  static func mapApproval(_ request: ServerApprovalRequest) -> ControlDeckApproval {
    let kind: ControlDeckApproval.Kind
    let title: String

    switch request.type {
      case .exec:
        title = request.toolName ?? "Tool Execution"
        kind = .tool(
          toolName: request.toolName,
          command: request.command,
          filePath: request.filePath,
          diff: request.diff
        )
      case .patch:
        title = request.filePath.map { "Edit \($0)" } ?? "File Edit"
        kind = .tool(
          toolName: request.toolName,
          command: nil,
          filePath: request.filePath,
          diff: request.diff
        )
      case .question:
        title = "Question"
        let prompts = request.questionPrompts.map { prompt in
          ControlDeckApproval.Prompt(
            id: prompt.id,
            question: prompt.question,
            options: prompt.options.map(\.label),
            allowsMultipleSelection: prompt.allowsMultipleSelection,
            allowsOther: prompt.allowsOther,
            isSecret: prompt.isSecret
          )
        }
        kind = .question(prompts: prompts)
      case .permissions:
        title = "Permission Request"
        let descriptions = request.requestedPermissions?.map(describePermission) ?? []
        kind = .permission(reason: request.permissionReason, descriptions: descriptions)
    }

    return ControlDeckApproval(
      requestId: request.id,
      sessionId: request.sessionId,
      kind: kind,
      title: title,
      detail: request.question ?? request.permissionReason
    )
  }

  private static func describePermission(_ perm: ServerPermissionDescriptor) -> String {
    switch perm {
      case let .filesystem(readPaths, writePaths):
        let parts = (readPaths.isEmpty ? [] : ["read: \(readPaths.joined(separator: ", "))"]) +
          (writePaths.isEmpty ? [] : ["write: \(writePaths.joined(separator: ", "))"])
        return "Filesystem \(parts.joined(separator: "; "))"
      case let .network(hosts):
        return "Network: \(hosts.joined(separator: ", "))"
      case let .macOs(entitlement, details):
        return details ?? entitlement
      case let .generic(permission, details):
        return details ?? permission
    }
  }

  private static func mapSnapshotKind(_ kind: ServerTokenUsageSnapshotKind) -> ControlDeckTokenUsageSnapshotKind {
    switch kind {
      case .unknown: .unknown
      case .contextTurn: .contextTurn
      case .lifetimeTotals: .lifetimeTotals
      case .mixedLegacy: .mixedLegacy
      case .compactionReset: .compactionReset
    }
  }

  private static func mapPickerOption(_ option: ServerControlDeckPickerOption) -> ControlDeckPickerOption {
    ControlDeckPickerOption(value: option.value, label: option.label)
  }

  private static func mapAutoReviewOption(_ option: ServerControlDeckAutoReviewOption) -> ControlDeckAutoReviewOption {
    ControlDeckAutoReviewOption(
      value: option.value,
      label: option.label,
      approvalPolicy: option.approvalPolicy,
      sandboxMode: option.sandboxMode
    )
  }

  private static func mapTokenTone(_ tone: ServerControlDeckTokenStatusTone) -> ControlDeckTokenStatus.Tone {
    switch tone {
      case .muted: .muted
      case .normal: .normal
      case .caution: .caution
      case .critical: .critical
    }
  }
}
