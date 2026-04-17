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
  @Environment(\.dismiss) var dismiss
  @Environment(ServerRuntimeRegistry.self) var runtimeRegistry
  @Environment(AppRouter.self) var router

  let continuation: SessionContinuation?
  private let endpointStore: ServerEndpointRuntime
  private let availableEndpointsOverride: [ServerEndpoint]?
  private let endpointSettings: ServerEndpointSettingsClient
  @State var model: NewSessionModel
  @State var codexConfigState = CodexConfigState()
  @State var presentation = PresentationState()
  @State var presetStore = SessionPresetStore()

  @MainActor
  init(
    provider: SessionProvider = .claude,
    continuation: SessionContinuation? = nil,
    endpointStore: ServerEndpointRuntime,
    availableEndpointsOverride: [ServerEndpoint]? = nil,
    endpointSettings: ServerEndpointSettingsClient? = nil
  ) {
    self.continuation = continuation
    self.endpointStore = endpointStore
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

  private var codexCapabilityNotice: CodexCapabilityNotice? {
    guard model.provider == .codex, !requiresCodexLogin else { return nil }
    guard let notice = CodexCapabilityNoticePlanner.notice(
      codexAccountStatus: endpointAppState.codexAccountStatus
    ) else {
      return nil
    }

    guard notice.style == .caution else { return nil }
    return notice
  }

  var claudeModels: [ServerClaudeModelOption] {
    ServerClaudeModelOption.defaults
  }

  var codexModels: [ServerCodexModelOption] {
    if scopedCodexModelProvider != nil {
      return codexConfigState.scopedModels ?? []
    }
    return endpointAppState.codexModels
  }

  private var codexModelOptionsSignature: String {
    codexModels.map(\.model).joined(separator: "|")
  }

  var selectableEndpoints: [ServerEndpoint] {
    let endpoints = availableEndpointsOverride ?? endpointSettings.endpoints()
    let enabled = endpoints.filter(\.isEnabled)
    return enabled.isEmpty ? endpoints : enabled
  }

  var endpointAppState: ServerEndpointRuntime {
    runtimeRegistry.endpointStore(for: model.selectedEndpointId)
  }

  var continuationDefaults: NewSessionContinuationDefaults? {
    guard let continuation else { return nil }
    return NewSessionContinuationDefaults(
      projectPath: continuation.projectPath,
      hasGitRepository: continuation.hasGitRepository
    )
  }

  var lifecycleState: NewSessionLifecycleState {
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
      isRemoteConnection: endpointAppState.isRemoteConnection,
      selectedServerInstanceId: endpointAppState.serverInstanceId
    )
  }

  var continuationPrompt: String? {
    guard let continuation, selectedEndpointSupportsContinuation else { return nil }
    return continuation.bootstrapPrompt()
  }

  private var shouldShowEndpointSection: Bool {
    selectableEndpoints.count > 1 || !isEndpointConnected
  }

  private var optionsSummary: String {
    if let presetName = presentation.activePresetName {
      return presetName
    }
    switch model.provider {
      case .claude:
        let modelName = model.claudeModelId.isEmpty ? "Default" : model.claudeModelId
        let permName = model.selectedPermissionMode.displayName
        return "\(modelName), \(permName)"
      case .codex:
        switch model.codexConfigMode {
          case .inherit: return "Inherited config"
          case .profile: return model.codexConfigProfile.isEmpty ? "Saved profile" : model.codexConfigProfile
          case .custom: return "Custom session"
        }
    }
  }

  // MARK: - Body

  var body: some View {
    NewSessionSheetShell(
      header: { header },
      formContent: { formContent },
      footer: { footer }
    )
    .sheet(isPresented: $presentation.showCodexInspector) {
      CodexConfigInspectorSheet(
        response: codexConfigState.inspectorResponse,
        errorMessage: codexConfigState.inspectorError,
        isLoading: codexConfigState.inspectorLoading,
        onRefresh: {
          inspectCodexConfig()
        },
        onManageConfig: {
          presentation.showCodexConfigManager = true
        }
      )
    }
    .sheet(isPresented: $presentation.showCodexConfigManager) {
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
            refreshScopedCodexModelsIfNeeded(force: true)
          }
        )
      }
    }
    .onAppear {
      applyOnAppearLifecycle()
      if continuation != nil {
        presentation.showOptions = true
      }
      refreshCodexConfigCatalogIfNeeded()
      refreshScopedCodexModelsIfNeeded()
    }
    .onChange(of: model.selectedPath) { _, newPath in
      applyPathChangeLifecycle(newPath)
      refreshCodexConfigCatalogIfNeeded()
      refreshScopedCodexModelsIfNeeded()
    }
    .onChange(of: model.selectedEndpointId) { _, newEndpointId in
      applyEndpointChangeLifecycle(newEndpointId)
      refreshCodexConfigCatalogIfNeeded()
      refreshScopedCodexModelsIfNeeded()
    }
    .onChange(of: model.provider) { _, _ in
      applyLifecyclePlan(NewSessionLifecyclePlanner.providerChanged(current: lifecycleState))
      presentation.activePresetName = nil
      refreshCodexConfigCatalogIfNeeded()
      refreshScopedCodexModelsIfNeeded()
    }
    .onChange(of: model.codexConfigMode) { _, _ in
      refreshScopedCodexModelsIfNeeded()
    }
    .onChange(of: model.codexModelProvider) { _, _ in
      refreshScopedCodexModelsIfNeeded()
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
    NewSessionQuickForm(
      showOptions: presentation.showOptions,
      onToggleOptions: {
        presentation.showOptions.toggle()
        if presentation.showOptions {
          presentation.activePresetName = nil
        }
      },
      shouldShowEndpointSection: shouldShowEndpointSection,
      continuation: continuation,
      isCodexProvider: model.provider == .codex,
      shouldShowAuthGate: requiresCodexLogin,
      shouldShowCodexCapabilityNotice: codexCapabilityNotice != nil,
      hasCodexError: model.provider == .codex && model.codexErrorMessage != nil,
      provider: model.provider,
      optionsSummary: optionsSummary,
      hasActivePreset: presentation.activePresetName != nil,
      providerToggle: { providerPicker },
      endpointSection: { endpointSection },
      continuationSection: { continuationSection($0) },
      authGateSection: { authGateSection },
      codexCapabilityNotice: { codexCapabilityNoticeSection },
      directorySection: { directorySection },
      presetRow: { presetRowContent },
      optionsPanel: { optionsPanel },
      errorBanner: {
        if let error = model.codexErrorMessage {
          errorBanner(error)
        }
      }
    )
  }

  // MARK: - Preset Row

  private var presetRowContent: some View {
    SessionPresetRow(
      provider: model.provider,
      presets: presetStore.presets(for: model.provider),
      onSelect: { preset in
        model.applyPreset(preset)
        syncModelSelections()
        withAnimation(Motion.standard) {
          presentation.activePresetName = preset.name
        }
      },
      onSave: { name in
        let preset = SessionPresetPlanner.capture(name: name, from: model)
        presetStore.save(preset)
      },
      onDelete: { id in
        presetStore.remove(id: id)
      }
    )
  }

  // MARK: - Options Panel

  private var optionsPanel: some View {
    NewSessionOptionsPanel(
      provider: model.provider,
      hasSelectedPath: !model.selectedPath.isEmpty,
      useWorktree: $model.useWorktree,
      worktreeBranch: $model.worktreeBranch,
      worktreeBaseBranch: $model.worktreeBaseBranch,
      worktreeError: $model.worktreeError,
      selectedPath: model.selectedPath,
      selectedPathIsGit: model.selectedPathIsGit,
      onGitInit: { initGitAndEnableWorktree() },
      configurationContent: { embeddedConfigurationCard },
      toolRestrictionsContent: { toolRestrictionsCard }
    )
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
        endpointAppState.codexAccountService.startLogin()
      },
      onCancelLogin: {
        endpointAppState.codexAccountService.cancelLogin()
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
      style: .embedded,
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
        endpointId: model.selectedEndpointId,

        style: .embedded
      )
    #endif
  }

  // MARK: - Configuration Card

  private var embeddedConfigurationCard: some View {
    NewSessionConfigurationCard(
      style: .embedded,
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
      hasSelectedPath: !model.selectedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      codexCatalogRequiresProjectPath: codexConfigState.catalogRequiresProjectPath,
      codexCatalog: codexConfigState.catalog,
      codexCatalogLoading: codexConfigState.catalogLoading,
      codexCatalogError: codexConfigState.catalogError,
      codexScopedModelProvider: scopedCodexModelProvider,
      codexScopedModelsLoading: codexConfigState.scopedModelsLoading,
      codexScopedModelError: codexConfigState.scopedModelsError,
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
        endpointAppState.codexAccountService.logout()
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
}

#Preview {
  let preview = PreviewRuntime(scenario: .newSession)
  preview.inject(
    NewSessionSheet(
      endpointStore: preview.endpointStore,
      availableEndpointsOverride: preview.endpoints
    )
  )
}

extension NewSessionSheet {
  struct PresentationState {
    var showCodexInspector = false
    var showCodexConfigManager = false
    var showOptions = false
    var activePresetName: String?
  }

  struct CodexConfigState {
    var inspectorResponse: SessionsClient.CodexInspectorResponse?
    var inspectorError: String?
    var inspectorLoading = false
    var catalog: SessionsClient.CodexConfigCatalogResponse?
    var catalogError: String?
    var catalogLoading = false
    var catalogRequestID = 0
    var catalogRequiresProjectPath = false
    var scopedModels: [ServerCodexModelOption]?
    var scopedModelsLoading = false
    var scopedModelsError: String?
    var scopedModelsRequestID = 0
  }
}
