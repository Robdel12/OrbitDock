//
//  NewSessionSheet.swift
//  OrbitDock
//
//  Unified sheet for creating new direct sessions (Claude or Codex).
//  Replaces the separate NewClaudeSessionSheet / NewCodexSessionSheet.
//

import SwiftUI

// MARK: - New Session Sheet

struct NewSessionSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(SessionStore.self) private var serverState
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry

  /// Pre-selected provider (set by caller)
  @State var provider: SessionProvider = .claude
  let continuation: SessionContinuation?
  private let availableEndpointsOverride: [ServerEndpoint]?
  private let endpointSettings: ServerEndpointSettingsClient

  // Shared state
  @State private var selectedPath: String = ""
  @State private var selectedPathIsGit: Bool = true
  @State private var selectedEndpointId: UUID
  @State private var isCreating = false
  @State private var useWorktree = false
  @State private var worktreeBranch = ""
  @State private var worktreeBaseBranch = ""
  @State private var worktreeError: String?

  // Claude-specific state
  @State private var claudeModelId: String = ""
  @State private var customModelInput: String = ""
  @State private var useCustomModel = false
  @State private var selectedPermissionMode: ClaudePermissionMode = .default
  @State private var allowedToolsText: String = ""
  @State private var disallowedToolsText: String = ""
  @State private var showToolConfig = false
  @State private var selectedEffort: ClaudeEffortLevel = .default

  // Codex-specific state
  @State private var codexModel: String = ""
  @State private var selectedAutonomy: AutonomyLevel = .autonomous
  @State private var codexErrorMessage: String?

  @MainActor
  init(
    provider: SessionProvider = .claude,
    continuation: SessionContinuation? = nil,
    availableEndpointsOverride: [ServerEndpoint]? = nil,
    endpointSettings: ServerEndpointSettingsClient? = nil
  ) {
    _provider = State(initialValue: provider)
    self.continuation = continuation
    self.availableEndpointsOverride = availableEndpointsOverride
    let resolvedEndpointSettings = endpointSettings ?? .live()
    self.endpointSettings = resolvedEndpointSettings
    let availableEndpoints = availableEndpointsOverride ?? resolvedEndpointSettings.endpoints()
    let initialEndpointId = ServerEndpointSelection.initialEndpointID(
      continuationEndpointID: continuation?.endpointId,
      availableEndpoints: availableEndpoints,
      fallbackDefaultEndpointID: resolvedEndpointSettings.defaultEndpoint().id
    )
    _selectedEndpointId = State(initialValue: initialEndpointId)
  }

  // MARK: - Computed Properties

  private var canCreateSession: Bool {
    let pathReady = !selectedPath.isEmpty
    let worktreeReady = !useWorktree || !worktreeBranch.trimmingCharacters(in: .whitespaces).isEmpty
    let continuationReady = continuation == nil || selectedEndpointSupportsContinuation

    switch provider {
      case .claude:
        return pathReady && worktreeReady && !isCreating && isEndpointConnected && continuationReady
      case .codex:
        return pathReady && !codexModel.isEmpty && worktreeReady && !isCreating && !requiresCodexLogin
          && isEndpointConnected && continuationReady
    }
  }

  private var requiresCodexLogin: Bool {
    endpointAppState.codexAccountStatus?.requiresOpenaiAuth == true
      && endpointAppState.codexAccountStatus?.account == nil
  }

  private var claudeModels: [ServerClaudeModelOption] {
    endpointAppState.claudeModels
  }

  private var codexModels: [ServerCodexModelOption] {
    endpointAppState.codexModels
  }

  private var resolvedClaudeModel: String? {
    if useCustomModel {
      let trimmed = customModelInput.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    return claudeModelId.isEmpty ? nil : claudeModelId
  }

  private var codexModelOptionsSignature: String {
    codexModels.map(\.model).joined(separator: "|")
  }

  private var selectableEndpoints: [ServerEndpoint] {
    let endpoints = availableEndpointsOverride ?? endpointSettings.endpoints()
    let enabled = endpoints.filter(\.isEnabled)
    return enabled.isEmpty ? endpoints : enabled
  }

  private var endpointAppState: SessionStore {
    runtimeRegistry.sessionStore(for: selectedEndpointId, fallback: serverState)
  }

  private var continuationDefaults: NewSessionContinuationDefaults? {
    guard let continuation else { return nil }
    return NewSessionContinuationDefaults(
      projectPath: continuation.projectPath,
      hasGitRepository: continuation.hasGitRepository
    )
  }

  private var lifecycleState: NewSessionLifecycleState {
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
        selectedAutonomy: selectedAutonomy,
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

  private var endpointStatus: ConnectionStatus {
    runtimeRegistry.displayConnectionStatus(for: selectedEndpointId)
  }

  private var isEndpointConnected: Bool {
    if case .connected = endpointStatus {
      return true
    }
    return false
  }

  private var selectedEndpointSupportsContinuation: Bool {
    guard let continuation else { return true }
    return continuation.isSupported(
      on: selectedEndpointId,
      isRemoteConnection: endpointAppState.isRemoteConnection
    )
  }

  private var continuationPrompt: String? {
    guard let continuation, selectedEndpointSupportsContinuation else { return nil }
    return continuation.bootstrapPrompt()
  }

  private var shouldShowEndpointSection: Bool {
    selectableEndpoints.count > 1 || !isEndpointConnected
  }

  private var formSectionSpacing: CGFloat {
    #if os(iOS)
      Spacing.lg
    #else
      Spacing.lg
    #endif
  }

  // MARK: - Body

  var body: some View {
    NewSessionSheetShell(
      header: { header },
      formContent: { formContent },
      footer: { footer }
    )
    .onAppear {
      applyLifecyclePlan(
        NewSessionLifecyclePlanner.onAppear(
          current: lifecycleState,
          selectableEndpoints: selectableEndpoints,
          primaryEndpointId: runtimeRegistry.primaryEndpointId,
          continuationEndpointId: continuation?.endpointId,
          continuationDefaults: continuationDefaults
        )
      )
    }
    .onChange(of: selectedPath) { _, newPath in
      applyLifecyclePlan(
        NewSessionLifecyclePlanner.pathChanged(
          current: lifecycleState,
          newPath: newPath
        )
      )
    }
    .onChange(of: selectedEndpointId) { _, newEndpointId in
      applyLifecyclePlan(
        NewSessionLifecyclePlanner.endpointChanged(
          current: lifecycleState,
          requestedEndpointId: newEndpointId,
          selectableEndpoints: selectableEndpoints,
          primaryEndpointId: runtimeRegistry.primaryEndpointId,
          continuationEndpointId: continuation?.endpointId,
          continuationDefaults: continuationDefaults
        )
      )
    }
    .onChange(of: provider) { _, _ in
      applyLifecyclePlan(NewSessionLifecyclePlanner.providerChanged(current: lifecycleState))
    }
    // Claude model sync
    .onChange(of: claudeModels.count) { _, _ in
      syncClaudeModelSelection()
    }
    // Codex model sync
    .onChange(of: codexModelOptionsSignature) { _, _ in
      syncCodexModelSelection()
    }
  }

  // MARK: - Form Content

  @ViewBuilder
  private var formContent: some View {
    NewSessionFormShell {
      formSections
    }
  }

  private var formSections: some View {
    NewSessionFormSections(
      formSectionSpacing: formSectionSpacing,
      shouldShowEndpointSection: shouldShowEndpointSection,
      continuation: continuation,
      isCodexProvider: provider == .codex,
      isClaudeProvider: provider == .claude,
      shouldShowAuthGate: endpointAppState.codexAccountStatus?.account == nil,
      hasSelectedPath: !selectedPath.isEmpty,
      hasCodexError: provider == .codex && codexErrorMessage != nil,
      providerPicker: { providerPicker },
      endpointSection: { endpointSection },
      continuationSection: { continuationSection($0) },
      authGateSection: { authGateSection },
      directorySection: { directorySection },
      worktreeSection: {
        WorktreeFormSection(
          useWorktree: $useWorktree,
          worktreeBranch: $worktreeBranch,
          worktreeBaseBranch: $worktreeBaseBranch,
          worktreeError: $worktreeError,
          selectedPath: selectedPath,
          selectedPathIsGit: selectedPathIsGit,
          onGitInit: { initGitAndEnableWorktree() }
        )
      },
      configurationCard: { configurationCard },
      toolRestrictionsCard: { toolRestrictionsCard },
      errorBanner: {
        if let error = codexErrorMessage {
          errorBanner(error)
        }
      }
    )
  }

  // MARK: - Provider Picker

  private var providerPicker: some View {
    NewSessionProviderPicker(
      provider: provider,
      onSelect: { provider = $0 }
    )
  }

  // MARK: - Header

  private var header: some View {
    NewSessionHeader(
      provider: provider,
      codexAccount: provider == .codex ? endpointAppState.codexAccountStatus?.account : nil,
      onDismiss: { dismiss() }
    )
  }

  // MARK: - Auth Gate (Codex only)

  @ViewBuilder
  private func continuationSection(_ continuation: SessionContinuation) -> some View {
    NewSessionContinuationSection(
      continuation: continuation,
      supportsContinuation: selectedEndpointSupportsContinuation
    )
  }

  private var authGateSection: some View {
    NewSessionAuthGateSection(
      loginInProgress: endpointAppState.codexAccountStatus?.loginInProgress == true,
      authError: endpointAppState.codexAuthError,
      onStartLogin: {
        endpointAppState.startCodexChatgptLogin()
      },
      onCancelLogin: {
        endpointAppState.cancelCodexChatgptLogin()
      }
    )
  }

  // MARK: - Endpoint & Directory

  private var endpointSection: some View {
    EndpointSelectorField(
      endpoints: selectableEndpoints,
      statusByEndpointId: runtimeRegistry.displayConnectionStatusByEndpointId,
      serverPrimaryByEndpointId: runtimeRegistry.serverPrimaryByEndpointId,
      selectedEndpointId: $selectedEndpointId,
      onReconnect: { endpointId in
        runtimeRegistry.reconnect(endpointId: endpointId)
      }
    )
  }

  private var directorySection: some View {
    #if os(iOS)
      RemoteProjectPicker(
        selectedPath: $selectedPath,
        selectedPathIsGit: $selectedPathIsGit,
        endpointId: selectedEndpointId
      )
    #else
      ProjectPicker(
        selectedPath: $selectedPath,
        selectedPathIsGit: $selectedPathIsGit,
        endpointId: selectedEndpointId
      )
    #endif
  }

  // MARK: - Configuration Card

  private var configurationCard: some View {
    NewSessionConfigurationCard(
      provider: provider,
      claudeModels: claudeModels,
      codexModels: codexModels,
      claudeModelId: $claudeModelId,
      customModelInput: $customModelInput,
      useCustomModel: $useCustomModel,
      selectedPermissionMode: $selectedPermissionMode,
      selectedEffort: $selectedEffort,
      codexModel: $codexModel,
      selectedAutonomy: $selectedAutonomy
    )
  }

  // MARK: - Tool Restrictions Card (Claude only)

  private var toolRestrictionsCard: some View {
    NewSessionToolRestrictionsCard(
      showToolConfig: $showToolConfig,
      allowedToolsText: $allowedToolsText,
      disallowedToolsText: $disallowedToolsText
    )
  }

  // MARK: - Footer

  private var footer: some View {
    NewSessionFooter(
      provider: provider,
      codexAccount: endpointAppState.codexAccountStatus?.account,
      isCreating: isCreating,
      canCreateSession: canCreateSession,
      onSignOut: {
        endpointAppState.logoutCodexAccount()
      },
      onCancel: {
        dismiss()
      },
      onLaunch: {
        createSession()
      }
    )
  }

  // MARK: - Helpers

  private func errorBanner(_ message: String) -> some View {
    NewSessionErrorBanner(message: message)
  }

  // MARK: - Actions

  private func refreshEndpointData() {
    // Models arrive via the event stream; only codex account needs an explicit refresh
    endpointAppState.refreshCodexAccount()
  }

  private func resetProviderState() {
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
    selectedAutonomy = state.selectedAutonomy
    codexErrorMessage = state.codexErrorMessage
  }

  private func syncModelSelections() {
    syncClaudeModelSelection()
    syncCodexModelSelection()
  }

  private func syncClaudeModelSelection() {
    let selection = NewSessionProviderStatePlanner.syncClaudeModelSelection(
      currentModelId: claudeModelId,
      useCustomModel: useCustomModel,
      models: claudeModels
    )
    claudeModelId = selection.modelId
    useCustomModel = selection.useCustomModel
  }

  private func syncCodexModelSelection() {
    codexModel = NewSessionProviderStatePlanner.syncCodexModelSelection(
      currentModel: codexModel,
      models: codexModels
    )
  }

  private func initGitAndEnableWorktree() {
    guard let runtime = runtimeRegistry.runtimesByEndpointId[selectedEndpointId] else { return }
    isCreating = true
    Task { @MainActor in
      defer { isCreating = false }
      do {
        let state = try await NewSessionLaunchCoordinator.initializeGit(
          at: selectedPath,
          using: launchPorts(store: endpointAppState, runtime: runtime)
        )
        selectedPathIsGit = state.selectedPathIsGit
        useWorktree = state.useWorktree
      } catch {
        worktreeError = "Failed to initialize git: \(error.localizedDescription)"
      }
    }
  }

  private func createSession() {
    guard let plan = NewSessionRequestPlanner.planLaunch(
      selectedPath: selectedPath,
      useWorktree: useWorktree,
      worktreeBranch: worktreeBranch,
      worktreeBaseBranch: worktreeBaseBranch,
      providerConfiguration: NewSessionProviderConfiguration(
        provider: provider,
        claudeModel: resolvedClaudeModel,
        claudePermissionMode: selectedPermissionMode,
        allowedToolsText: allowedToolsText,
        disallowedToolsText: disallowedToolsText,
        claudeEffort: selectedEffort.serialized,
        codexModel: codexModel,
        codexAutonomy: selectedAutonomy
      ),
      bootstrapPrompt: continuationPrompt
    ) else {
      return
    }

    switch plan.target {
      case let .worktree(repoPath, branch, baseBranch):
        createSessionWithWorktree(plan: plan, repoPath: repoPath, branch: branch, baseBranch: baseBranch)
      case .direct:
        createSessionDirect(plan: plan)
    }
  }

  private func createSessionWithWorktree(
    plan: NewSessionLaunchPlan,
    repoPath: String,
    branch: String,
    baseBranch: String?
  ) {
    guard let runtime = runtimeRegistry.runtimesByEndpointId[selectedEndpointId] else { return }
    isCreating = true
    worktreeError = nil
    let store = endpointAppState
    Task { @MainActor in
      do {
        let worktreePath = try await NewSessionLaunchCoordinator.createWorktree(
          repoPath: repoPath,
          branchName: branch,
          baseBranch: baseBranch,
          using: launchPorts(store: store, runtime: runtime)
        )
        launchSession(plan: plan, cwd: worktreePath, store: store, runtime: runtime)
        dismiss()
      } catch {
        isCreating = false
        worktreeError = error.localizedDescription
      }
    }
  }

  private func createSessionDirect(plan: NewSessionLaunchPlan) {
    guard case let .direct(cwd) = plan.target else { return }
    launchSession(plan: plan, cwd: cwd, store: endpointAppState, runtime: nil)
    dismiss()
  }

  private func launchSession(
    plan: NewSessionLaunchPlan,
    cwd: String,
    store: SessionStore,
    runtime: ServerRuntime?
  ) {
    let request = plan.requestTemplate.makeRequest(cwd: cwd)

    Task {
      _ = try? await NewSessionLaunchCoordinator.launchSession(
        request: request,
        continuationPrompt: plan.bootstrapPrompt,
        using: launchPorts(store: store, runtime: runtime)
      )
    }
  }

  private func launchPorts(store: SessionStore, runtime: ServerRuntime?) -> NewSessionLaunchPorts {
    NewSessionLaunchPorts(
      gitInit: { path in
        guard let runtime else { throw NewSessionLaunchCoordinatorError.runtimeUnavailable }
        _ = try await runtime.clients.worktrees.gitInit(path: path)
      },
      createWorktree: { repoPath, branchName, baseBranch in
        guard let runtime else { throw NewSessionLaunchCoordinatorError.runtimeUnavailable }
        let worktree = try await runtime.clients.worktrees.createWorktree(
          repoPath: repoPath,
          branchName: branchName,
          baseBranch: baseBranch
        )
        return worktree.worktreePath
      },
      createSession: { request in
        let response = try await store.createSession(request)
        return response.sessionId
      },
      sendBootstrapPrompt: { sessionId, prompt in
        try await store.clients.conversation.sendMessage(
          sessionId,
          request: ConversationClient.SendMessageRequest(content: prompt)
        )
      }
    )
  }

  private func applyLifecyclePlan(_ plan: NewSessionLifecyclePlan) {
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
    selectedAutonomy = providerState.selectedAutonomy
    codexErrorMessage = providerState.codexErrorMessage

    let worktreeState = plan.nextState.worktreeState
    useWorktree = worktreeState.useWorktree
    worktreeBranch = worktreeState.branch
    worktreeBaseBranch = worktreeState.baseBranch
    worktreeError = worktreeState.error

    if plan.shouldRefreshEndpointData {
      refreshEndpointData()
    }
    if plan.shouldSyncModelSelections {
      syncModelSelections()
    }
  }
}

#Preview {
  let preview = PreviewRuntime(scenario: .newSession)
  preview.inject(
    NewSessionSheet(availableEndpointsOverride: preview.endpoints)
  )
}
