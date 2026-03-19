import Foundation

struct NewSessionModel {
  var provider: SessionProvider
  var selectedPath: String
  var selectedPathIsGit: Bool
  var selectedEndpointId: UUID
  var isCreating: Bool

  var useWorktree: Bool
  var worktreeBranch: String
  var worktreeBaseBranch: String
  var worktreeError: String?

  var claudeModelId: String
  var customModelInput: String
  var useCustomModel: Bool
  var selectedPermissionMode: ClaudePermissionMode
  var allowBypassPermissions: Bool
  var allowedToolsText: String
  var disallowedToolsText: String
  var showToolConfig: Bool
  var selectedEffort: ClaudeEffortLevel

  var codexModel: String
  var codexUseOrbitDockOverrides: Bool
  var selectedAutonomy: AutonomyLevel
  var codexCollaborationMode: CodexCollaborationMode
  var codexMultiAgentEnabled: Bool
  var codexPersonality: CodexPersonalityPreset
  var codexServiceTier: CodexServiceTierPreset
  var codexInstructions: String
  var codexErrorMessage: String?

  init(provider: SessionProvider, selectedEndpointId: UUID) {
    self.provider = provider
    self.selectedPath = ""
    self.selectedPathIsGit = true
    self.selectedEndpointId = selectedEndpointId
    self.isCreating = false
    self.useWorktree = false
    self.worktreeBranch = ""
    self.worktreeBaseBranch = ""
    self.worktreeError = nil
    self.claudeModelId = ""
    self.customModelInput = ""
    self.useCustomModel = false
    self.selectedPermissionMode = .default
    self.allowBypassPermissions = false
    self.allowedToolsText = ""
    self.disallowedToolsText = ""
    self.showToolConfig = false
    self.selectedEffort = .default
    self.codexModel = ""
    self.codexUseOrbitDockOverrides = false
    self.selectedAutonomy = .autonomous
    self.codexCollaborationMode = .default
    self.codexMultiAgentEnabled = false
    self.codexPersonality = .automatic
    self.codexServiceTier = .automatic
    self.codexInstructions = ""
    self.codexErrorMessage = nil
  }

  var resolvedClaudeModel: String? {
    if useCustomModel {
      let trimmed = customModelInput.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    return claudeModelId.isEmpty ? nil : claudeModelId
  }

  var lifecycleState: NewSessionLifecycleState {
    NewSessionLifecycleState(
      selectedEndpointId: selectedEndpointId,
      selectedPath: selectedPath,
      selectedPathIsGit: selectedPathIsGit,
      providerState: NewSessionProviderState(
        claudeModelId: claudeModelId,
        customModelInput: customModelInput,
        useCustomModel: useCustomModel,
        selectedPermissionMode: selectedPermissionMode,
        allowedToolsText: allowedToolsText,
        disallowedToolsText: disallowedToolsText,
        showToolConfig: showToolConfig,
        selectedEffort: selectedEffort,
        codexModel: codexModel,
        codexUseOrbitDockOverrides: codexUseOrbitDockOverrides,
        selectedAutonomy: selectedAutonomy,
        codexCollaborationMode: codexCollaborationMode,
        codexMultiAgentEnabled: codexMultiAgentEnabled,
        codexPersonality: codexPersonality,
        codexServiceTier: codexServiceTier,
        codexInstructions: codexInstructions,
        codexErrorMessage: codexErrorMessage
      ),
      worktreeState: NewSessionWorktreeState(
        useWorktree: useWorktree,
        branch: worktreeBranch,
        baseBranch: worktreeBaseBranch,
        error: worktreeError
      )
    )
  }

  var providerConfiguration: NewSessionProviderConfiguration {
    NewSessionProviderConfiguration(
      provider: provider,
      claudeModel: resolvedClaudeModel,
      claudePermissionMode: selectedPermissionMode,
      claudeAllowBypassPermissions: allowBypassPermissions,
      allowedToolsText: allowedToolsText,
      disallowedToolsText: disallowedToolsText,
      claudeEffort: selectedEffort.serialized,
      codexModel: codexModel,
      codexUseOrbitDockOverrides: codexUseOrbitDockOverrides,
      codexAutonomy: selectedAutonomy,
      codexCollaborationMode: codexCollaborationMode.rawValue,
      codexMultiAgentEnabled: codexMultiAgentEnabled,
      codexPersonality: codexPersonality.requestValue,
      codexServiceTier: codexServiceTier.requestValue,
      codexInstructions: codexInstructions
    )
  }

  func canCreateSession(
    isEndpointConnected: Bool,
    requiresCodexLogin: Bool,
    continuationSupported: Bool
  ) -> Bool {
    let pathReady = !selectedPath.isEmpty
    let worktreeReady = !useWorktree || !worktreeBranch.trimmingCharacters(in: .whitespaces).isEmpty
    let continuationReady = continuationSupported

    switch provider {
      case .claude:
        return pathReady && worktreeReady && !isCreating && isEndpointConnected && continuationReady
      case .codex:
        let modelReady = codexUseOrbitDockOverrides ? !codexModel.isEmpty : true
        return pathReady && modelReady && worktreeReady && !isCreating && !requiresCodexLogin
          && isEndpointConnected && continuationReady
    }
  }

  mutating func applyLifecyclePlan(_ plan: NewSessionLifecyclePlan) {
    selectedEndpointId = plan.nextState.selectedEndpointId
    selectedPath = plan.nextState.selectedPath
    selectedPathIsGit = plan.nextState.selectedPathIsGit

    let providerState = plan.nextState.providerState
    claudeModelId = providerState.claudeModelId
    customModelInput = providerState.customModelInput
    useCustomModel = providerState.useCustomModel
    selectedPermissionMode = providerState.selectedPermissionMode
    allowedToolsText = providerState.allowedToolsText
    disallowedToolsText = providerState.disallowedToolsText
    showToolConfig = providerState.showToolConfig
    selectedEffort = providerState.selectedEffort
    codexModel = providerState.codexModel
    codexUseOrbitDockOverrides = providerState.codexUseOrbitDockOverrides
    selectedAutonomy = providerState.selectedAutonomy
    codexCollaborationMode = providerState.codexCollaborationMode
    codexMultiAgentEnabled = providerState.codexMultiAgentEnabled
    codexPersonality = providerState.codexPersonality
    codexServiceTier = providerState.codexServiceTier
    codexInstructions = providerState.codexInstructions
    codexErrorMessage = providerState.codexErrorMessage

    let worktreeState = plan.nextState.worktreeState
    useWorktree = worktreeState.useWorktree
    worktreeBranch = worktreeState.branch
    worktreeBaseBranch = worktreeState.baseBranch
    worktreeError = worktreeState.error
  }

  mutating func resetProviderState() {
    let state = NewSessionProviderStatePlanner.reset()
    claudeModelId = state.claudeModelId
    customModelInput = state.customModelInput
    useCustomModel = state.useCustomModel
    selectedPermissionMode = state.selectedPermissionMode
    allowedToolsText = state.allowedToolsText
    disallowedToolsText = state.disallowedToolsText
    showToolConfig = state.showToolConfig
    selectedEffort = state.selectedEffort
    codexModel = state.codexModel
    codexUseOrbitDockOverrides = state.codexUseOrbitDockOverrides
    selectedAutonomy = state.selectedAutonomy
    codexCollaborationMode = state.codexCollaborationMode
    codexMultiAgentEnabled = state.codexMultiAgentEnabled
    codexPersonality = state.codexPersonality
    codexServiceTier = state.codexServiceTier
    codexInstructions = state.codexInstructions
    codexErrorMessage = state.codexErrorMessage
  }

  mutating func syncClaudeModelSelection(models: [ServerClaudeModelOption]) {
    let selection = NewSessionProviderStatePlanner.syncClaudeModelSelection(
      currentModelId: claudeModelId,
      useCustomModel: useCustomModel,
      models: models
    )
    claudeModelId = selection.modelId
    useCustomModel = selection.useCustomModel
  }

  mutating func syncCodexModelSelection(models: [ServerCodexModelOption]) {
    codexModel = NewSessionProviderStatePlanner.syncCodexModelSelection(
      currentModel: codexModel,
      shouldPreferDefaultModel: codexUseOrbitDockOverrides,
      models: models
    )
  }
}
