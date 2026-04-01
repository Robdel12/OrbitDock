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
        kind = .tool(mapToolApproval(request))
      case .patch:
        title = request.filePath.flatMap { formatFilePath($0) } ?? "File Edit"
        kind = .patch(mapPatchApproval(request))
      case .question:
        title = request.questionPrompts.count > 1 ? "Questions" : "Question"
        kind = .question(prompts: mapPrompts(request.questionPrompts))
      case .permissions:
        title = "Permission Request"
        kind = .permission(mapPermissionApproval(request))
    }

    return ControlDeckApproval(
      requestId: request.id,
      sessionId: request.sessionId,
      kind: kind,
      title: title,
      detail: request.question ?? request.permissionReason,
      riskLevel: mapRiskLevel(request.preview?.riskLevel),
      riskFindings: request.preview?.riskFindings ?? [],
      previewType: mapPreviewType(request.preview?.type),
      decisionScope: request.preview?.decisionScope,
      proposedAmendment: request.proposedAmendment,
      mcpServerName: request.mcpServerName,
      elicitation: mapElicitation(request),
      networkHost: request.networkHost,
      networkProtocol: request.networkProtocol
    )
  }

  // MARK: - Tool Approval

  private static func mapToolApproval(_ request: ServerApprovalRequest) -> ControlDeckApproval.ToolApproval {
    let segments = request.preview?.shellSegments ?? []
    let commandChain: [ControlDeckApproval.CommandSegment] = segments.enumerated().map { index, segment in
      ControlDeckApproval.CommandSegment(
        index: index,
        command: segment.command,
        chainOperator: index > 0 ? segment.leadingOperator : nil
      )
    }

    return ControlDeckApproval.ToolApproval(
      toolName: request.toolName,
      command: request.command ?? request.preview?.value,
      filePath: request.filePath,
      commandChain: commandChain
    )
  }

  // MARK: - Patch Approval

  private static func mapPatchApproval(_ request: ServerApprovalRequest) -> ControlDeckApproval.PatchApproval {
    ControlDeckApproval.PatchApproval(
      toolName: request.toolName,
      filePath: request.filePath,
      diff: request.diff
    )
  }

  // MARK: - Question Prompts

  private static func mapPrompts(_ prompts: [ServerApprovalQuestionPrompt]) -> [ControlDeckApproval.Prompt] {
    prompts.map { prompt in
      ControlDeckApproval.Prompt(
        id: prompt.id,
        header: prompt.header,
        question: prompt.question,
        options: prompt.options.map { option in
          ControlDeckApproval.PromptOption(
            label: option.label,
            description: option.description
          )
        },
        allowsMultipleSelection: prompt.allowsMultipleSelection,
        allowsOther: prompt.allowsOther,
        isSecret: prompt.isSecret
      )
    }
  }

  // MARK: - Permission Approval

  private static func mapPermissionApproval(_ request: ServerApprovalRequest) -> ControlDeckApproval.PermissionApproval {
    let groups = groupPermissions(request.requestedPermissions ?? [])
    return ControlDeckApproval.PermissionApproval(
      reason: request.permissionReason,
      groups: groups
    )
  }

  private static func groupPermissions(_ descriptors: [ServerPermissionDescriptor]) -> [ControlDeckApproval.PermissionGroup] {
    var networkItems: [ControlDeckApproval.PermissionItem] = []
    var filesystemItems: [ControlDeckApproval.PermissionItem] = []
    var macOsItems: [ControlDeckApproval.PermissionItem] = []
    var genericItems: [ControlDeckApproval.PermissionItem] = []

    for descriptor in descriptors {
      switch descriptor {
        case let .network(hosts):
          if hosts.isEmpty {
            networkItems.append(ControlDeckApproval.PermissionItem(action: "access", target: "any host"))
          } else {
            for host in hosts {
              networkItems.append(ControlDeckApproval.PermissionItem(action: "access", target: host))
            }
          }

        case let .filesystem(readPaths, writePaths):
          for path in readPaths {
            filesystemItems.append(ControlDeckApproval.PermissionItem(action: "read", target: path))
          }
          for path in writePaths {
            filesystemItems.append(ControlDeckApproval.PermissionItem(action: "write", target: path))
          }

        case let .macOs(entitlement, details):
          let target = formatMacOsEntitlement(entitlement: entitlement, details: details)
          macOsItems.append(ControlDeckApproval.PermissionItem(action: entitlement, target: target))

        case let .generic(permission, details):
          genericItems.append(ControlDeckApproval.PermissionItem(
            action: permission,
            target: details ?? permission
          ))
      }
    }

    var groups: [ControlDeckApproval.PermissionGroup] = []
    if !networkItems.isEmpty {
      groups.append(ControlDeckApproval.PermissionGroup(category: .network, items: networkItems))
    }
    if !filesystemItems.isEmpty {
      groups.append(ControlDeckApproval.PermissionGroup(category: .filesystem, items: filesystemItems))
    }
    if !macOsItems.isEmpty {
      groups.append(ControlDeckApproval.PermissionGroup(category: .macOs, items: macOsItems))
    }
    if !genericItems.isEmpty {
      groups.append(ControlDeckApproval.PermissionGroup(category: .generic, items: genericItems))
    }
    return groups
  }

  private static func formatMacOsEntitlement(entitlement: String, details: String?) -> String {
    switch entitlement {
      case "preferences":
        switch details {
          case "read_write": return "Read and write system preferences"
          case "read_only": return "Read system preferences"
          default: return details ?? "System preferences"
        }
      case "automation":
        if let details {
          return details == "all" ? "Automate all apps" : "Automate \(details)"
        }
        return "App automation"
      case "accessibility":
        return "Accessibility control"
      case "calendar":
        return "Calendar access"
      default:
        return details ?? entitlement
    }
  }

  // MARK: - Elicitation

  private static func mapElicitation(_ request: ServerApprovalRequest) -> ControlDeckApproval.Elicitation? {
    guard let mode = request.elicitationMode else { return nil }
    return ControlDeckApproval.Elicitation(
      mode: mapElicitationMode(mode),
      url: request.elicitationUrl,
      message: request.elicitationMessage
    )
  }

  private static func mapElicitationMode(_ mode: ServerElicitationMode) -> ControlDeckApproval.Elicitation.Mode {
    switch mode {
      case .form: .form
      case .url: .url
    }
  }

  // MARK: - Risk & Preview

  private static func mapRiskLevel(_ level: ServerApprovalRiskLevel?) -> ControlDeckApproval.RiskLevel {
    switch level {
      case .low: .low
      case .normal: .normal
      case .high: .high
      case .none: .normal
    }
  }

  private static func mapPreviewType(_ type: ServerApprovalPreviewType?) -> ControlDeckApproval.PreviewType {
    switch type {
      case .shellCommand: .shellCommand
      case .diff: .diff
      case .url: .url
      case .searchQuery: .searchQuery
      case .pattern: .pattern
      case .prompt: .prompt
      case .value: .value
      case .filePath: .filePath
      case .action, .none: .action
    }
  }

  // MARK: - Formatting Helpers

  private static func formatFilePath(_ path: String) -> String {
    let components = path.split(separator: "/")
    guard components.count > 0 else { return path }

    // Show parent/filename for context (e.g., "Edit Views/MyFile.swift")
    if components.count >= 2 {
      let parent = components[components.count - 2]
      let fileName = components[components.count - 1]
      return "Edit \(parent)/\(fileName)"
    }

    return "Edit \(components.last!)"
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
