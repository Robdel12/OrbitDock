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
  @Environment(AppRouter.self) private var router

  let continuation: SessionContinuation?
  private let availableEndpointsOverride: [ServerEndpoint]?
  private let endpointSettings: ServerEndpointSettingsClient
  @State private var model: NewSessionModel
  @State private var codexInspectorResponse: SessionsClient.CodexInspectorResponse?
  @State private var codexInspectorError: String?
  @State private var codexInspectorLoading = false
  @State private var showCodexInspector = false
  @State private var showCodexConfigManager = false
  @State private var codexConfigCatalog: SessionsClient.CodexConfigCatalogResponse?
  @State private var codexConfigCatalogError: String?
  @State private var codexConfigCatalogLoading = false
  @State private var codexConfigCatalogRequestID = 0

  @MainActor
  init(
    provider: SessionProvider = .claude,
    continuation: SessionContinuation? = nil,
    availableEndpointsOverride: [ServerEndpoint]? = nil,
    endpointSettings: ServerEndpointSettingsClient? = nil
  ) {
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
    _model = State(initialValue: NewSessionModel(provider: provider, selectedEndpointId: initialEndpointId))
  }

  // MARK: - Computed Properties

  private var canCreateSession: Bool {
    model.canCreateSession(
      isEndpointConnected: isEndpointConnected,
      requiresCodexLogin: requiresCodexLogin,
      continuationSupported: continuation == nil || selectedEndpointSupportsContinuation
    )
  }

  private var requiresCodexLogin: Bool {
    endpointAppState.codexAccountStatus?.requiresOpenaiAuth == true
      && endpointAppState.codexAccountStatus?.account == nil
  }

  private var codexCapabilityNotice: McpCapabilityNotice? {
    guard model.provider == .codex, !requiresCodexLogin else { return nil }
    guard let notice = McpServersTabPlanner.capabilityNotice(
      provider: .codex,
      codexAccountStatus: endpointAppState.codexAccountStatus
    ) else {
      return nil
    }

    guard notice.style == .caution else { return nil }
    return notice
  }

  private var claudeModels: [ServerClaudeModelOption] {
    ServerClaudeModelOption.defaults
  }

  private var codexModels: [ServerCodexModelOption] {
    endpointAppState.codexModels
  }

  private var resolvedClaudeModel: String? {
    model.resolvedClaudeModel
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
    runtimeRegistry.sessionStore(for: model.selectedEndpointId, fallback: serverState)
  }

  private var continuationDefaults: NewSessionContinuationDefaults? {
    guard let continuation else { return nil }
    return NewSessionContinuationDefaults(
      projectPath: continuation.projectPath,
      hasGitRepository: continuation.hasGitRepository
    )
  }

  private var lifecycleState: NewSessionLifecycleState {
    model.lifecycleState
  }

  private var endpointStatus: ConnectionStatus {
    runtimeRegistry.displayConnectionStatus(for: model.selectedEndpointId)
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
      on: model.selectedEndpointId,
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
    .sheet(isPresented: $showCodexInspector) {
      CodexConfigInspectorSheet(
        response: codexInspectorResponse,
        errorMessage: codexInspectorError,
        isLoading: codexInspectorLoading,
        onRefresh: {
          inspectCodexConfig()
        },
        onManageConfig: {
          showCodexConfigManager = true
        }
      )
    }
    .sheet(isPresented: $showCodexConfigManager) {
      if let normalizedProjectPathForConfigEditor {
        CodexConfigManagerSheet(
          cwd: normalizedProjectPathForConfigEditor,
          fetchDocuments: { cwd in
            try await endpointAppState.clients.sessions.fetchCodexConfigDocuments(cwd: cwd)
          },
          batchWrite: { request in
            try await endpointAppState.clients.sessions.batchWriteCodexConfig(request)
          },
          onDidChange: {
            refreshCodexConfigCatalogIfNeeded(force: true)
          }
        )
      }
    }
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
      refreshCodexConfigCatalogIfNeeded()
    }
    .onChange(of: model.selectedPath) { _, newPath in
      applyLifecyclePlan(
        NewSessionLifecyclePlanner.pathChanged(
          current: lifecycleState,
          newPath: newPath
        )
      )
      refreshCodexConfigCatalogIfNeeded()
    }
    .onChange(of: model.selectedEndpointId) { _, newEndpointId in
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
      refreshCodexConfigCatalogIfNeeded()
    }
    .onChange(of: model.provider) { _, _ in
      applyLifecyclePlan(NewSessionLifecyclePlanner.providerChanged(current: lifecycleState))
      refreshCodexConfigCatalogIfNeeded()
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
      isCodexProvider: model.provider == .codex,
      isClaudeProvider: model.provider == .claude,
      shouldShowAuthGate: requiresCodexLogin,
      shouldShowCodexCapabilityNotice: codexCapabilityNotice != nil,
      hasSelectedPath: !model.selectedPath.isEmpty,
      hasCodexError: model.provider == .codex && model.codexErrorMessage != nil,
      providerPicker: { providerPicker },
      endpointSection: { endpointSection },
      continuationSection: { continuationSection($0) },
      authGateSection: { authGateSection },
      codexCapabilityNoticeSection: { codexCapabilityNoticeSection },
      directorySection: { directorySection },
      worktreeSection: {
        WorktreeFormSection(
          useWorktree: $model.useWorktree,
          worktreeBranch: $model.worktreeBranch,
          worktreeBaseBranch: $model.worktreeBaseBranch,
          worktreeError: $model.worktreeError,
          selectedPath: model.selectedPath,
          selectedPathIsGit: model.selectedPathIsGit,
          onGitInit: { initGitAndEnableWorktree() }
        )
      },
      configurationCard: { configurationCard },
      toolRestrictionsCard: { toolRestrictionsCard },
      errorBanner: {
        if let error = model.codexErrorMessage {
          errorBanner(error)
        }
      }
    )
  }

  private func inspectCodexConfig() {
    guard !model.selectedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      codexInspectorError =
        "Choose a project folder first so OrbitDock can resolve the Codex config that applies there, including user and project-level layers."
      codexInspectorResponse = nil
      showCodexInspector = true
      return
    }

    codexInspectorLoading = true
    codexInspectorError = nil
    showCodexInspector = true

    let shouldApplyOverrides = model.codexConfigMode == .custom
    let request = SessionsClient.CodexInspectRequest(
      cwd: model.selectedPath,
      codexConfigSource: .user,
      codexConfigMode: model.codexConfigMode,
      codexConfigProfile: normalizedCodexProfile,
      model: shouldApplyOverrides ? model.codexModel : nil,
      modelProvider: shouldApplyOverrides ? normalizedCodexModelProvider : nil,
      approvalPolicy: shouldApplyOverrides ? model.selectedAutonomy.approvalPolicy : nil,
      approvalPolicyDetails: shouldApplyOverrides ? model.selectedAutonomy.approvalPolicyDetails : nil,
      sandboxMode: shouldApplyOverrides ? model.selectedAutonomy.sandboxMode : nil,
      collaborationMode: shouldApplyOverrides ? model.codexCollaborationMode.rawValue : nil,
      multiAgent: shouldApplyOverrides ? model.codexMultiAgentEnabled : nil,
      personality: shouldApplyOverrides ? model.codexPersonality.requestValue : nil,
      serviceTier: shouldApplyOverrides ? model.codexServiceTier.requestValue : nil,
      developerInstructions: shouldApplyOverrides ? normalizedCodexInstructions : nil,
      effort: nil
    )

    Task {
      do {
        codexInspectorResponse = try await endpointAppState.clients.sessions.inspectCodexConfig(request)
      } catch {
        codexInspectorResponse = nil
        codexInspectorError = error.localizedDescription
      }
      codexInspectorLoading = false
    }
  }

  private func openCodexConfigManager() {
    guard normalizedProjectPathForConfigEditor != nil else {
      codexInspectorError =
        "Choose a project folder first so OrbitDock can resolve the Codex config layers that apply here before editing saved profiles and providers."
      codexInspectorResponse = nil
      showCodexInspector = true
      return
    }
    showCodexConfigManager = true
  }

  private var normalizedCodexInstructions: String? {
    let trimmed = model.codexInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private var normalizedCodexProfile: String? {
    let trimmed = model.codexConfigProfile.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private var normalizedCodexModelProvider: String? {
    let trimmed = model.codexModelProvider.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private var normalizedProjectPathForConfigEditor: String? {
    let trimmed = model.selectedPath.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  @ViewBuilder
  private var codexCapabilityNoticeSection: some View {
    if let codexCapabilityNotice {
      CodexCapabilityNoticeCard(notice: codexCapabilityNotice)
    }
  }

  // MARK: - Provider Picker

  private var providerPicker: some View {
    NewSessionProviderPicker(
      provider: model.provider,
      onSelect: { model.provider = $0 }
    )
  }

  // MARK: - Header

  private var header: some View {
    NewSessionHeader(
      provider: model.provider,
      codexAccount: model.provider == .codex ? endpointAppState.codexAccountStatus?.account : nil,
      onDismiss: { dismiss() }
    )
  }

  // MARK: - Auth Gate (Codex only)

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
      selectedEndpointId: $model.selectedEndpointId,
      onReconnect: { endpointId in
        runtimeRegistry.reconnect(endpointId: endpointId)
      }
    )
  }

  private var directorySection: some View {
    #if os(iOS)
      RemoteProjectPicker(
        selectedPath: $model.selectedPath,
        selectedPathIsGit: $model.selectedPathIsGit,
        endpointId: model.selectedEndpointId
      )
    #else
      ProjectPicker(
        selectedPath: $model.selectedPath,
        selectedPathIsGit: $model.selectedPathIsGit,
        endpointId: model.selectedEndpointId
      )
    #endif
  }

  // MARK: - Configuration Card

  private var configurationCard: some View {
    NewSessionConfigurationCard(
      provider: model.provider,
      claudeModels: claudeModels,
      codexModels: codexModels,
      claudeModelId: $model.claudeModelId,
      customModelInput: $model.customModelInput,
      useCustomModel: $model.useCustomModel,
      selectedPermissionMode: $model.selectedPermissionMode,
      allowBypassPermissions: $model.allowBypassPermissions,
      selectedEffort: $model.selectedEffort,
      codexModel: $model.codexModel,
      codexConfigMode: $model.codexConfigMode,
      codexConfigProfile: $model.codexConfigProfile,
      codexModelProvider: $model.codexModelProvider,
      selectedAutonomy: $model.selectedAutonomy,
      codexCollaborationMode: $model.codexCollaborationMode,
      codexMultiAgentEnabled: $model.codexMultiAgentEnabled,
      codexPersonality: $model.codexPersonality,
      codexServiceTier: $model.codexServiceTier,
      codexInstructions: $model.codexInstructions,
      codexCatalog: codexConfigCatalog,
      codexCatalogLoading: codexConfigCatalogLoading,
      codexCatalogError: codexConfigCatalogError,
      onInspectCodexConfig: inspectCodexConfig,
      onManageCodexConfig: openCodexConfigManager
    )
  }

  // MARK: - Tool Restrictions Card (Claude only)

  private var toolRestrictionsCard: some View {
    NewSessionToolRestrictionsCard(
      showToolConfig: $model.showToolConfig,
      allowedToolsText: $model.allowedToolsText,
      disallowedToolsText: $model.disallowedToolsText
    )
  }

  // MARK: - Footer

  private var footer: some View {
    NewSessionFooter(
      provider: model.provider,
      codexAccount: endpointAppState.codexAccountStatus?.account,
      isCreating: model.isCreating,
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
    guard model.provider == .codex else { return }
    endpointAppState.refreshCodexModels()
    endpointAppState.refreshCodexAccount()
  }

  private func resetProviderState() {
    model.resetProviderState()
  }

  private func syncModelSelections() {
    syncClaudeModelSelection()
    syncCodexModelSelection()
  }

  private func syncClaudeModelSelection() {
    model.syncClaudeModelSelection(models: claudeModels)
  }

  private func syncCodexModelSelection() {
    model.syncCodexModelSelection(models: codexModels)
  }

  private func refreshCodexConfigCatalogIfNeeded(force _: Bool = false) {
    guard model.provider == .codex else {
      codexConfigCatalog = nil
      codexConfigCatalogError = nil
      codexConfigCatalogLoading = false
      return
    }

    let cwd = model.selectedPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cwd.isEmpty else {
      codexConfigCatalog = nil
      codexConfigCatalogError = nil
      codexConfigCatalogLoading = false
      return
    }

    codexConfigCatalogLoading = true
    codexConfigCatalogError = nil
    codexConfigCatalogRequestID += 1
    let requestID = codexConfigCatalogRequestID

    Task {
      do {
        let response = try await endpointAppState.clients.sessions.fetchCodexConfigCatalog(cwd: cwd)
        await MainActor.run {
          guard requestID == codexConfigCatalogRequestID,
                model.provider == .codex,
                model.selectedPath.trimmingCharacters(in: .whitespacesAndNewlines) == cwd
          else { return }
          codexConfigCatalog = response
          codexConfigCatalogLoading = false
          if model.codexConfigMode == .profile,
             model.codexConfigProfile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          {
            model.codexConfigProfile = response.profiles.first?.name ?? ""
          }
          if model.codexConfigMode == .custom,
             model.codexModelProvider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          {
            model.codexModelProvider = response.providers.first?.id ?? ""
          }
        }
      } catch {
        await MainActor.run {
          guard requestID == codexConfigCatalogRequestID,
                model.provider == .codex,
                model.selectedPath.trimmingCharacters(in: .whitespacesAndNewlines) == cwd
          else { return }
          codexConfigCatalog = nil
          codexConfigCatalogError = error.localizedDescription
          codexConfigCatalogLoading = false
        }
      }
    }
  }

  private func initGitAndEnableWorktree() {
    guard let runtime = runtimeRegistry.runtimesByEndpointId[model.selectedEndpointId] else { return }
    model.isCreating = true
    Task { @MainActor in
      defer { model.isCreating = false }
      do {
        let state = try await NewSessionLaunchCoordinator.initializeGit(
          at: model.selectedPath,
          using: launchPorts(store: endpointAppState, runtime: runtime)
        )
        model.selectedPathIsGit = state.selectedPathIsGit
        model.useWorktree = state.useWorktree
      } catch {
        model.worktreeError = "Failed to initialize git: \(error.localizedDescription)"
      }
    }
  }

  private func createSession() {
    guard let plan = NewSessionRequestPlanner.planLaunch(
      selectedPath: model.selectedPath,
      useWorktree: model.useWorktree,
      worktreeBranch: model.worktreeBranch,
      worktreeBaseBranch: model.worktreeBaseBranch,
      providerConfiguration: model.providerConfiguration,
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
    guard let runtime = runtimeRegistry.runtimesByEndpointId[model.selectedEndpointId] else { return }
    model.isCreating = true
    model.worktreeError = nil
    let store = endpointAppState
    Task { @MainActor in
      do {
        let worktreePath = try await NewSessionLaunchCoordinator.createWorktree(
          repoPath: repoPath,
          branchName: branch,
          baseBranch: baseBranch,
          using: launchPorts(store: store, runtime: runtime)
        )
        try await launchSession(plan: plan, cwd: worktreePath, store: store, runtime: runtime)
        dismiss()
      } catch {
        model.isCreating = false
        model.worktreeError = error.localizedDescription
      }
    }
  }

  private func createSessionDirect(plan: NewSessionLaunchPlan) {
    guard case let .direct(cwd) = plan.target else { return }
    model.isCreating = true
    let store = endpointAppState
    Task { @MainActor in
      do {
        try await launchSession(plan: plan, cwd: cwd, store: store, runtime: nil)
        dismiss()
      } catch {
        model.isCreating = false
        model.codexErrorMessage = error.localizedDescription
      }
    }
  }

  private func launchSession(
    plan: NewSessionLaunchPlan,
    cwd: String,
    store: SessionStore,
    runtime: ServerRuntime?
  ) async throws {
    let request = plan.requestTemplate.makeRequest(cwd: cwd)
    let createdSessionId = try await NewSessionLaunchCoordinator.launchSession(
      request: request,
      continuationPrompt: plan.bootstrapPrompt,
      using: launchPorts(store: store, runtime: runtime)
    )
    model.isCreating = false
    if let createdSessionId {
      router.selectSession(SessionRef(endpointId: store.endpointId, sessionId: createdSessionId))
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
    model.applyLifecyclePlan(plan)

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
