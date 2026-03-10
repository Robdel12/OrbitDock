//
//  NewSessionSheet.swift
//  OrbitDock
//
//  Unified sheet for creating new direct sessions (Claude or Codex).
//  Replaces the separate NewClaudeSessionSheet / NewCodexSessionSheet.
//

import SwiftUI

// MARK: - Session Provider

enum SessionProvider: String, CaseIterable, Identifiable {
  case claude
  case codex

  var id: String { rawValue }

  var displayName: String {
    switch self {
      case .claude: "Claude"
      case .codex: "Codex"
    }
  }

  var color: Color {
    switch self {
      case .claude: .providerClaude
      case .codex: .providerCodex
    }
  }

  var icon: String {
    switch self {
      case .claude: "sparkles"
      case .codex: "chevron.left.forwardslash.chevron.right"
    }
  }
}

// MARK: - Effort Level (Claude)

enum ClaudeEffortLevel: String, CaseIterable, Identifiable {
  case `default` = ""
  case low
  case medium
  case high
  case max

  var id: String { rawValue }

  var displayName: String {
    switch self {
      case .default: "Default"
      case .low: "Low"
      case .medium: "Medium"
      case .high: "High"
      case .max: "Max"
    }
  }

  var description: String {
    switch self {
      case .default: "Use provider default effort"
      case .low: "Balanced speed with focused reasoning"
      case .medium: "Standard depth for general tasks"
      case .high: "In-depth analysis for complex work"
      case .max: "Maximum depth for hardest problems"
    }
  }

  var icon: String {
    switch self {
      case .default: "sparkles"
      case .low: "hare.fill"
      case .medium: "gauge.medium"
      case .high: "gauge.high"
      case .max: "flame.fill"
    }
  }

  var color: Color {
    switch self {
      case .default: .textSecondary
      case .low: .effortLow
      case .medium: .effortMedium
      case .high: .effortHigh
      case .max: .effortXHigh
    }
  }

  var serialized: String? {
    self == .default ? nil : rawValue
  }
}

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
    VStack(spacing: 0) {
      header

      Divider()
        .overlay(Color.surfaceBorder)

      formContent

      Divider()
        .overlay(Color.surfaceBorder)

      footer
    }
    #if os(iOS)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    #else
    .frame(minWidth: 500, idealWidth: 600, maxWidth: 700)
    #endif
    .background(Color.backgroundSecondary)
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
    #if os(iOS)
      ScrollView(showsIndicators: false) {
        formSections
          .padding(.horizontal, Spacing.lg)
          .padding(.vertical, Spacing.lg)
          .padding(.bottom, Spacing.sm)
      }
    #else
      ScrollView(showsIndicators: true) {
        formSections
          .padding(.horizontal, Spacing.xl)
          .padding(.vertical, Spacing.lg)
      }
    #endif
  }

  private var formSections: some View {
    VStack(alignment: .leading, spacing: formSectionSpacing) {
      providerPicker

      if shouldShowEndpointSection {
        endpointSection
      }

      if let continuation {
        continuationSection(continuation)
      }

      if provider == .codex, endpointAppState.codexAccountStatus?.account == nil {
        authGateSection
      }

      directorySection

      if !selectedPath.isEmpty {
        WorktreeFormSection(
          useWorktree: $useWorktree,
          worktreeBranch: $worktreeBranch,
          worktreeBaseBranch: $worktreeBaseBranch,
          worktreeError: $worktreeError,
          selectedPath: selectedPath,
          selectedPathIsGit: selectedPathIsGit,
          onGitInit: { initGitAndEnableWorktree() }
        )
      }

      configurationCard

      if provider == .claude {
        toolRestrictionsCard
      }

      if provider == .codex, let error = codexErrorMessage {
        errorBanner(error)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
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

// MARK: - Compact Claude Permission Selector

struct CompactClaudePermissionSelector: View {
  @Binding var selection: ClaudePermissionMode
  @State private var hoveredMode: ClaudePermissionMode?

  private let modes = ClaudePermissionMode.allCases

  var body: some View {
    HStack(spacing: Spacing.sm) {
      ForEach(modes) { mode in
        CompactModeButton(
          icon: mode.icon,
          color: mode.color,
          isActive: mode == selection,
          isHovered: hoveredMode == mode && mode != selection,
          helpText: mode.displayName,
          onTap: { selection = mode },
          onHover: { hovering in hoveredMode = hovering ? mode : nil }
        )
      }
    }
    #if !os(iOS)
    .onHover { hovering in
      if hovering {
        NSCursor.pointingHand.push()
      } else {
        NSCursor.pop()
        hoveredMode = nil
      }
    }
    #endif
    .animation(Motion.bouncy, value: hoveredMode)
    .animation(Motion.bouncy, value: selection)
  }
}

// MARK: - Compact Autonomy Selector

struct CompactAutonomySelector: View {
  @Binding var selection: AutonomyLevel
  @State private var hoveredLevel: AutonomyLevel?

  private let levels = AutonomyLevel.allCases

  var body: some View {
    HStack(spacing: Spacing.sm) {
      ForEach(levels) { level in
        CompactModeButton(
          icon: level.icon,
          color: level.color,
          isActive: level == selection,
          isHovered: hoveredLevel == level && level != selection,
          helpText: level.displayName,
          onTap: { selection = level },
          onHover: { hovering in hoveredLevel = hovering ? level : nil }
        )
      }
    }
    #if !os(iOS)
    .onHover { hovering in
      if hovering {
        NSCursor.pointingHand.push()
      } else {
        NSCursor.pop()
        hoveredLevel = nil
      }
    }
    #endif
    .animation(Motion.bouncy, value: hoveredLevel)
    .animation(Motion.bouncy, value: selection)
  }
}

// MARK: - Compact Mode Button (shared)

private struct CompactModeButton: View {
  let icon: String
  let color: Color
  let isActive: Bool
  let isHovered: Bool
  let helpText: String
  let onTap: () -> Void
  let onHover: (Bool) -> Void

  var body: some View {
    Button(action: {
      onTap()
      #if os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
      #endif
    }) {
      let iconColor = isActive ? Color.backgroundSecondary : (isHovered ? color : color.opacity(0.6))
      let scale = isActive ? 1.05 : 1.0

      Image(systemName: icon)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(iconColor)
        .frame(width: 30, height: 30)
        .background(backgroundCircle)
        .overlay(strokeCircle)
        .themeShadow(Shadow.glow(color: isActive ? color : .clear))
        .scaleEffect(scale)
    }
    .buttonStyle(.plain)
    #if !os(iOS)
      .onHover(perform: onHover)
      .help(helpText)
    #endif
      .contentShape(Circle())
  }

  @ViewBuilder
  private var backgroundCircle: some View {
    if isActive {
      Circle().fill(color)
    } else if isHovered {
      Circle().fill(color.opacity(OpacityTier.light))
    } else {
      Circle().fill(Color.clear)
    }
  }

  @ViewBuilder
  private var strokeCircle: some View {
    let strokeColor = isActive ? Color
      .clear : (isHovered ? color.opacity(OpacityTier.strong) : color.opacity(0.3))
    let strokeWidth: CGFloat = isActive ? 0 : (isHovered ? 1.5 : 1)

    Circle().stroke(strokeColor, lineWidth: strokeWidth)
  }
}

#Preview {
  let preview = PreviewRuntime(scenario: .newSession)
  preview.inject(
    NewSessionSheet(availableEndpointsOverride: preview.endpoints)
  )
}
