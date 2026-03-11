import SwiftUI

extension DirectSessionComposer {
  var obs: SessionObservable {
    serverState.session(sessionId)
  }

  var sessionSummary: Session? {
    serverState.sessions.first(where: { $0.id == sessionId })
  }

  var currentContinuation: SessionContinuation {
    SessionContinuation(
      endpointId: serverState.endpointId,
      sessionId: sessionId,
      provider: obs.provider,
      displayName: sessionSummary?.displayName ?? obs.displayName,
      projectPath: obs.projectPath,
      model: obs.model,
      hasGitRepository: obs.branch != nil || obs.repositoryRoot != nil || obs.isWorktree
    )
  }

  var canContinueInNewSession: Bool {
    !serverState.isRemoteConnection
  }

  var pendingApprovalModel: ApprovalCardModel? {
    guard let summary = sessionSummary else { return nil }
    return ApprovalCardModelBuilder.build(
      session: summary,
      pendingApproval: obs.pendingApproval,
      approvalHistory: obs.approvalHistory,
      transcriptMessages: serverState.conversation(sessionId).messages
    )
  }

  var pendingApprovalIdentity: String {
    pendingApprovalModel?.approvalId ?? ""
  }

  var inputMode: InputMode {
    if manualShellMode { return .shell }
    if manualReviewMode { return .reviewNotes }
    if isSessionWorking { return .steer }
    return .prompt
  }

  var composerBorderColor: Color {
    if let model = pendingApprovalModel {
      return pendingPanelModeColor(model)
    }

    switch inputMode {
      case .steer: return .composerSteer
      case .reviewNotes: return .composerReview
      case .shell: return .composerShell
      default: return .composerPrompt
    }
  }

  var isSessionWorking: Bool {
    obs.workStatus == .working
  }

  var isSessionActive: Bool {
    obs.isActive
  }

  var draftStorageKey: String {
    "endpoint:\(serverState.endpointId.uuidString)::session:\(sessionId)"
  }

  var connectionStatus: ConnectionStatus {
    runtimeRegistry.displayConnectionStatus(for: serverState.endpointId)
  }

  var isConnected: Bool {
    if case .connected = connectionStatus {
      return true
    }
    return false
  }

  var connectionPillTint: Color {
    switch connectionStatus {
      case .connected:
        .feedbackPositive
      case .connecting:
        .feedbackCaution
      case .disconnected:
        .textQuaternary
      case .failed:
        .statusError
    }
  }

  var connectionPillIcon: String {
    switch connectionStatus {
      case .connected:
        "network"
      case .connecting:
        "arrow.triangle.2.circlepath"
      case .disconnected:
        "wifi.slash"
      case .failed:
        "exclamationmark.triangle.fill"
    }
  }

  var connectionPillLabel: String {
    switch connectionStatus {
      case .connected:
        "Connected"
      case .connecting:
        "Reconnecting"
      case .disconnected:
        "Offline"
      case .failed:
        "Connect failed"
    }
  }

  var connectionNoticeMessage: String? {
    switch connectionStatus {
      case .connected:
        return nil
      case .connecting:
        return "Reconnecting to server. Messages sent now will queue and auto-send."
      case .disconnected:
        return "Server disconnected. Messages sent now will queue and auto-send."
      case let .failed(reason):
        if reason.isEmpty {
          return "Server connection failed. Messages sent now will queue and auto-send."
        }
        return "Server connection failed (\(reason)). Messages sent now will queue and auto-send."
    }
  }

  var showReconnectButton: Bool {
    switch connectionStatus {
      case .disconnected, .failed:
        true
      case .connecting, .connected:
        false
    }
  }

  var hasOverrides: Bool {
    DirectSessionComposerProviderPlanner.hasOverrides(
      providerMode: providerMode,
      selectedCodexModel: selectedModel,
      selectedClaudeModel: selectedClaudeModel,
      currentModel: obs.model,
      selectedEffort: selectedEffort,
      codexOptions: codexModelOptions,
      claudeOptions: claudeModelOptions
    )
  }

  var availableSkills: [ServerSkillMetadata] {
    serverState.session(sessionId).skills.filter(\.enabled)
  }

  var filteredSkills: [ServerSkillMetadata] {
    guard !inputState.skillCompletion.query.isEmpty else { return availableSkills }
    let q = inputState.skillCompletion.query.lowercased()
    return availableSkills.filter { $0.name.lowercased().contains(q) }
  }

  var shouldShowCompletion: Bool {
    inputState.skillCompletion.isActive && !filteredSkills.isEmpty
  }

  var hasInlineSkills: Bool {
    !DirectSessionComposerSkillPlanner.inlineSkillNames(
      in: message,
      availableSkillNames: Set(availableSkills.map(\.name))
    ).isEmpty
  }

  var codexModelOptions: [ServerCodexModelOption] {
    serverState.codexModels
  }

  var currentCodexModelOption: ServerCodexModelOption? {
    codexModelOptions.first(where: { $0.model == (composerState.selectedModel.isEmpty ? obs.model : composerState.selectedModel) })
      ?? codexModelOptions.first(where: { $0.model == obs.model })
      ?? codexModelOptions.first(where: \.isDefault)
      ?? codexModelOptions.first
  }

  var currentCodexCollaborationMode: CodexCollaborationMode {
    CodexCollaborationMode.from(rawValue: obs.collaborationMode, permissionMode: obs.permissionMode)
  }

  var currentCodexMultiAgentEnabled: Bool {
    obs.multiAgent ?? false
  }

  var currentCodexPersonality: CodexPersonalityPreset {
    CodexPersonalityPreset.from(serverValue: obs.personality)
  }

  var currentCodexServiceTier: CodexServiceTierPreset {
    CodexServiceTierPreset.from(serverValue: obs.serviceTier)
  }

  var hasCodexControlOverrides: Bool {
    currentCodexCollaborationMode != .default
      || currentCodexMultiAgentEnabled
      || currentCodexPersonality != .automatic
      || currentCodexServiceTier != .automatic
      || !(obs.developerInstructions?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
  }

  var codexModelOptionsSignature: String {
    codexModelOptions.map(\.model).joined(separator: "|")
  }

  var claudeModelOptions: [ServerClaudeModelOption] {
    serverState.claudeModels
  }

  var claudeModelOptionsSignature: String {
    claudeModelOptions.map(\.value).joined(separator: "|")
  }

  var defaultCodexModelSelection: String {
    DirectSessionComposerProviderPlanner.defaultCodexModelSelection(
      currentModel: obs.model,
      options: codexModelOptions
    )
  }

  var defaultClaudeModelSelection: String {
    DirectSessionComposerProviderPlanner.defaultClaudeModelSelection(
      currentModel: obs.model,
      options: claudeModelOptions
    )
  }

  var effectiveClaudeModel: String {
    DirectSessionComposerProviderPlanner.effectiveClaudeModel(
      selectedClaudeModel: selectedClaudeModel,
      sessionModel: obs.model,
      options: claudeModelOptions
    )
  }

  var projectPath: String? {
    let normalized = obs.projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
  }

  var fileIndex: ProjectFileIndex {
    serverState.projectFileIndex
  }

  var forkWorktreeDisplayRepoPath: String? {
    if let root = obs.repositoryRoot?.trimmingCharacters(in: .whitespacesAndNewlines), !root.isEmpty {
      return root
    }
    if !obs.projectPath.isEmpty {
      return obs.projectPath
    }
    return nil
  }

  var forkToExistingCandidates: [ServerWorktreeSummary] {
    guard let repoPath = forkWorktreeDisplayRepoPath else { return [] }
    return serverState.worktrees(for: repoPath)
      .filter {
        $0.status != .removed && $0.diskPresent && $0.worktreePath != repoPath
      }
      .sorted { $0.createdAt > $1.createdAt }
  }

  var canForkConversation: Bool {
    !obs.forkInProgress
  }

  var canForkToWorktree: Bool {
    forkWorktreeDisplayRepoPath != nil && canForkConversation
  }

  var canForkToExistingWorktree: Bool {
    forkWorktreeDisplayRepoPath != nil && canForkConversation
  }

  var filteredFiles: [ProjectFileIndex.ProjectFile] {
    guard let path = projectPath else { return [] }
    return fileIndex.search(inputState.mentionCompletion.query, in: path)
  }

  var shouldShowMentionCompletion: Bool {
    inputState.mentionCompletion.isActive && !filteredFiles.isEmpty
  }

  var shouldShowCommandDeck: Bool {
    inputState.commandDeck.isActive && !commandDeckItems.isEmpty
  }

  var hasSkillsPanel: Bool {
    obs.isDirectCodex || serverState.session(sessionId).hasClaudeSkills
  }

  var hasMcpData: Bool {
    serverState.session(sessionId).hasMcpData
  }

  var mcpToolEntries: [ComposerMcpToolEntry] {
    DirectSessionComposerCommandDeckPlanner.mcpToolEntries(from: serverState.session(sessionId).mcpTools)
  }

  var mcpResourceEntries: [ComposerMcpResourceEntry] {
    DirectSessionComposerCommandDeckPlanner.mcpResourceEntries(from: serverState.session(sessionId).mcpResources)
  }

  var mcpResourceTemplateEntries: [ComposerMcpResourceTemplateEntry] {
    DirectSessionComposerCommandDeckPlanner.mcpResourceTemplateEntries(
      from: serverState.session(sessionId).mcpResourceTemplates
    )
  }

  var commandDeckItems: [ComposerCommandDeckItem] {
    let projectFiles: [ProjectFileIndex.ProjectFile]
    if let path = projectPath {
      let query = inputState.commandDeck.query.trimmingCharacters(in: .whitespacesAndNewlines)
      projectFiles = if query.isEmpty {
        Array(fileIndex.files(for: path).prefix(7))
      } else {
        Array(fileIndex.search(query, in: path).prefix(9))
      }
    } else {
      projectFiles = []
    }

    return DirectSessionComposerCommandDeckPlanner.buildItems(
      DirectSessionComposerCommandDeckContext(
        query: inputState.commandDeck.query,
        hasSkillsPanel: hasSkillsPanel,
        hasMcpData: hasMcpData,
        manualShellMode: manualShellMode,
        projectFiles: projectFiles,
        availableSkills: availableSkills,
        mcpToolEntries: mcpToolEntries,
        mcpResourceEntries: mcpResourceEntries,
        mcpResourceTemplateEntries: mcpResourceTemplateEntries
      )
    )
  }

  var filePickerResults: [ProjectFileIndex.ProjectFile] {
    guard let path = projectPath else { return [] }
    let trimmed = filePickerQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return Array(fileIndex.files(for: path).prefix(220))
    }
    return Array(fileIndex.search(trimmed, in: path).prefix(300))
  }

  var hasAttachments: Bool {
    attachmentState.hasAttachments
  }

  var attachedImagesBinding: Binding<[AttachedImage]> {
    Binding(
      get: { attachmentState.images },
      set: { attachmentState.images = $0 }
    )
  }

  var attachedMentionsBinding: Binding<[AttachedMention]> {
    Binding(
      get: { attachmentState.mentions },
      set: { attachmentState.mentions = $0 }
    )
  }

  var isDictationActive: Bool {
    dictationController.state == .recording ||
      dictationController.state == .requestingPermission ||
      dictationController.state == .transcribing
  }

  var shouldShowDictation: Bool {
    localDictationEnabled && LocalDictationAvailabilityResolver.current == .available
  }

  var composerErrorMessage: String? {
    errorMessage ?? dictationController.errorMessage
  }

  var latestConversationUserMessage: TranscriptMessage? {
    serverState.conversation(sessionId).messages.last(where: \.isUser)
  }

  var composerPlaceholder: String {
    if inputMode == .shell { return "Run a shell command..." }
    if isSessionWorking { return "Steer the current turn..." }
    return "Send a message..."
  }

  var isCompactLayout: Bool {
    horizontalSizeClass == .compact
  }
}
