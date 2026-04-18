import Foundation

enum ControlDeckSnapshotMapper {
  @MainActor
  static func map(
    _ payload: ServerSessionDetailSnapshotPayload,
    codexModels: [ServerCodexModelOption]
  ) -> ControlDeckSnapshot {
    let session = payload.session
    return ControlDeckSnapshot(
      revision: payload.revision,
      sessionId: session.id,
      state: mapState(session),
      capabilities: mapCapabilities(session, codexModels: codexModels),
      preferences: defaultPreferences(),
      tokenUsage: mapTokenUsage(session.tokenUsage),
      tokenUsageSnapshotKind: mapSnapshotKind(session.tokenUsageSnapshotKind),
      tokenStatus: buildTokenStatus(session),
      pendingApproval: session.pendingApproval.map(mapApproval)
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

  private static func mapState(_ session: ServerSessionState) -> ControlDeckSessionState {
    ControlDeckSessionState(
      provider: mapProvider(session.provider),
      controlMode: mapControlMode(session.controlMode),
      lifecycle: mapLifecycle(session.lifecycleState),
      workStatus: mapWorkStatus(session.workStatus),
      acceptsUserInput: session.acceptsUserInput,
      steerable: session.steerable,
      canInterrupt: session.canInterrupt ?? false,
      // Detail owns session shell truth. A resumable or ended lifecycle means
      // the direct connector is no longer attached enough for interactive work.
      connectorAttached: session.lifecycleState == .open,
      projectPath: session.projectPath,
      currentCwd: session.currentCwd,
      gitBranch: session.gitBranch,
      config: mapConfig(session)
    )
  }

  private static func mapCapabilities(
    _ session: ServerSessionState,
    codexModels: [ServerCodexModelOption]
  ) -> ControlDeckCapabilities {
    let selectedCodexModel = selectedCodexModelOption(for: session, codexModels: codexModels)
    return ControlDeckCapabilities(
      supportsSkills: session.provider == .codex,
      supportsMentions: session.provider == .codex,
      supportsImages: true,
      supportsSteer: session.steerable,
      allowPerTurnModelOverride: true,
      allowPerTurnEffortOverride: session.provider == .codex,
      effortOptions: effortOptions(for: session, selectedCodexModel: selectedCodexModel),
      approvalModeOptions: approvalModeOptions(for: session.provider),
      permissionModeOptions: permissionModeOptions(for: session.provider),
      collaborationModeOptions: collaborationModeOptions(
        for: session.provider,
        selectedCodexModel: selectedCodexModel
      ),
      autoReviewOptions: [],
      availableStatusModules: availableStatusModules(for: session.provider)
    )
  }

  private static func mapConfig(_ session: ServerSessionState) -> ControlDeckConfig {
    ControlDeckConfig(
      model: session.model,
      effort: session.effort,
      approvalPolicy: session.approvalPolicy,
      approvalPolicyDetails: session.approvalPolicyDetails,
      sandboxMode: session.sandboxMode,
      sandboxPolicyDetails: session.sandboxPolicyDetails,
      approvalsReviewer: session.codexConfigOverrides?.approvalsReviewer,
      permissionMode: session.permissionMode,
      collaborationMode: session.collaborationMode
    )
  }

  private static func defaultPreferences() -> ControlDeckPreferences {
    ControlDeckPreferences(
      density: .comfortable,
      showWhenEmpty: .auto,
      modules: [
        .init(module: .autonomy, visible: true),
        .init(module: .approvalMode, visible: true),
        .init(module: .collaborationMode, visible: true),
        .init(module: .autoReview, visible: true),
        .init(module: .attachments, visible: true),
        .init(module: .model, visible: true),
        .init(module: .effort, visible: true),
        .init(module: .tokens, visible: true),
        .init(module: .branch, visible: true),
        .init(module: .cwd, visible: true),
      ]
    )
  }

  private static func approvalModeOptions(for provider: ServerProvider) -> [ControlDeckPickerOption] {
    guard provider == .codex else { return [] }
    return [
      .init(value: "untrusted", label: "Trusted Only"),
      .init(value: "on-failure", label: "On Failure"),
      .init(value: "on-request", label: "Default"),
      .init(value: "never", label: "Never Ask"),
    ]
  }

  private static func permissionModeOptions(for provider: ServerProvider) -> [ControlDeckPickerOption] {
    guard provider == .claude else { return [] }
    return ClaudePermissionMode.allCases.map {
      ControlDeckPickerOption(value: $0.rawValue, label: $0.displayName)
    }
  }

  private static func collaborationModeOptions(
    for provider: ServerProvider,
    selectedCodexModel: ServerCodexModelOption?
  ) -> [ControlDeckPickerOption] {
    guard provider == .codex else { return [] }
    return CodexCollaborationMode.supportedCases(from: selectedCodexModel).map {
      ControlDeckPickerOption(value: $0.rawValue, label: $0.displayName)
    }
  }

  private static func effortOptions(
    for session: ServerSessionState,
    selectedCodexModel: ServerCodexModelOption?
  ) -> [ControlDeckPickerOption] {
    switch session.provider {
      case .claude:
        return [
          .init(value: "low", label: "Low"),
          .init(value: "medium", label: "Medium"),
          .init(value: "high", label: "High"),
          .init(value: "max", label: "Max"),
        ]
      case .codex:
        let efforts = selectedCodexModel?.supportedReasoningEfforts ?? ["none", "minimal", "low", "medium", "high", "xhigh"]
        return uniqueLowercased(efforts).map { effort in
          ControlDeckPickerOption(value: effort, label: effortLabel(for: effort))
        }
    }
  }

  private static func availableStatusModules(for provider: ServerProvider) -> [ControlDeckStatusModule] {
    let shared: [ControlDeckStatusModule] = [.model, .effort, .tokens, .branch, .cwd]
    switch provider {
      case .claude:
        return [.autonomy] + shared
      case .codex:
        return [.approvalMode, .collaborationMode, .attachments] + shared
    }
  }

  private static func selectedCodexModelOption(
    for session: ServerSessionState,
    codexModels: [ServerCodexModelOption]
  ) -> ServerCodexModelOption? {
    guard session.provider == .codex else { return nil }
    guard let model = session.model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else {
      return codexModels.first(where: \.isDefault) ?? codexModels.first
    }
    return codexModels.first {
      $0.model.caseInsensitiveCompare(model) == .orderedSame
        || $0.id.caseInsensitiveCompare(model) == .orderedSame
    }
  }

  private static func uniqueLowercased(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    var ordered: [String] = []
    for value in values {
      let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      guard !normalized.isEmpty else { continue }
      guard seen.insert(normalized).inserted else { continue }
      ordered.append(normalized)
    }
    return ordered
  }

  private static func effortLabel(for value: String) -> String {
    switch value {
      case "none": return "None"
      case "minimal": return "Minimal"
      case "low": return "Low"
      case "medium": return "Medium"
      case "high": return "High"
      case "xhigh": return "XHigh"
      case "max": return "Max"
      default:
        let first = value.prefix(1).uppercased()
        return first + value.dropFirst()
    }
  }

  private static func buildTokenStatus(_ session: ServerSessionState) -> ControlDeckTokenStatus {
    let usage = session.tokenUsage
    guard usage.contextWindow > 0 else {
      return ControlDeckTokenStatus(label: "—", tone: .muted)
    }

    let effectiveInput = effectiveContextInputTokens(
      provider: session.provider,
      usage: usage,
      snapshotKind: session.tokenUsageSnapshotKind
    )
    let fillPercent = Double(effectiveInput) / Double(usage.contextWindow) * 100
    let displayPercent: String
    if effectiveInput > 0, fillPercent > 0, fillPercent < 1 {
      displayPercent = "<1"
    } else {
      displayPercent = "\(UInt64(fillPercent.rounded(.down)))"
    }

    return ControlDeckTokenStatus(
      label: "\(displayPercent)% · \(formatTokenCount(effectiveInput))/\(formatTokenCount(usage.contextWindow))",
      tone: tokenTone(fillPercent)
    )
  }

  private static func effectiveContextInputTokens(
    provider: ServerProvider,
    usage: ServerTokenUsage,
    snapshotKind: ServerTokenUsageSnapshotKind
  ) -> UInt64 {
    switch snapshotKind {
      case .mixedLegacy:
        saturatingAdd(usage.inputTokens, usage.cachedTokens)
      case .compactionReset:
        0
      case .contextTurn:
        provider == .claude
          ? saturatingAdd(usage.inputTokens, usage.cachedTokens)
          : usage.inputTokens
      case .lifetimeTotals:
        usage.inputTokens
      case .unknown:
        provider == .codex
          ? usage.inputTokens
          : saturatingAdd(usage.inputTokens, usage.cachedTokens)
    }
  }

  private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? .max : result
  }

  private static func tokenTone(_ fillPercent: Double) -> ControlDeckTokenStatus.Tone {
    if fillPercent > 90 { return .critical }
    if fillPercent > 70 { return .caution }
    return .normal
  }

  private static func formatTokenCount(_ count: UInt64) -> String {
    if count >= 1_000_000 {
      return String(format: "%.1fM", Double(count) / 1_000_000)
    }
    if count >= 1_000 {
      return String(format: "%.0fK", Double(count) / 1_000)
    }
    return "\(count)"
  }

  // MARK: - Shared Mapping

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

  private static func mapWorkStatus(_ status: ServerWorkStatus) -> ControlDeckWorkStatus {
    switch status {
      case .working: .working
      case .waiting: .waiting
      case .permission: .permission
      case .question: .question
      case .reply: .reply
      case .ended: .ended
    }
  }

  private static func mapLifecycle(_ state: ServerSessionLifecycleState) -> ControlDeckLifecycle {
    switch state {
      case .open: .open
      case .resumable: .resumable
      case .ended: .ended
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

  private static func mapSnapshotKind(_ kind: ServerTokenUsageSnapshotKind) -> ControlDeckTokenUsageSnapshotKind {
    switch kind {
      case .unknown: .unknown
      case .contextTurn: .contextTurn
      case .lifetimeTotals: .lifetimeTotals
      case .mixedLegacy: .mixedLegacy
      case .compactionReset: .compactionReset
    }
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

  private static func mapPatchApproval(_ request: ServerApprovalRequest) -> ControlDeckApproval.PatchApproval {
    ControlDeckApproval.PatchApproval(
      toolName: request.toolName,
      filePath: request.filePath,
      diff: request.diff
    )
  }

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
            networkItems.append(.init(action: "access", target: "any host"))
          } else {
            for host in hosts {
              networkItems.append(.init(action: "access", target: host))
            }
          }
        case let .filesystem(readPaths, writePaths):
          for path in readPaths {
            filesystemItems.append(.init(action: "read", target: path))
          }
          for path in writePaths {
            filesystemItems.append(.init(action: "write", target: path))
          }
        case let .macOs(entitlement, details):
          macOsItems.append(.init(action: entitlement, target: formatMacOsEntitlement(entitlement: entitlement, details: details)))
        case let .generic(permission, details):
          genericItems.append(.init(action: permission, target: details ?? permission))
      }
    }

    var groups: [ControlDeckApproval.PermissionGroup] = []
    if !networkItems.isEmpty { groups.append(.init(category: .network, items: networkItems)) }
    if !filesystemItems.isEmpty { groups.append(.init(category: .filesystem, items: filesystemItems)) }
    if !macOsItems.isEmpty { groups.append(.init(category: .macOs, items: macOsItems)) }
    if !genericItems.isEmpty { groups.append(.init(category: .generic, items: genericItems)) }
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

  private static func formatFilePath(_ path: String) -> String {
    let components = path.split(separator: "/")
    guard !components.isEmpty else { return path }
    if components.count >= 2 {
      let parent = components[components.count - 2]
      let fileName = components[components.count - 1]
      return "Edit \(parent)/\(fileName)"
    }
    return "Edit \(components.last!)"
  }
}
