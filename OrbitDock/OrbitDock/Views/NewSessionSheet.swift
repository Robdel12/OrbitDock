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

private enum ClaudeEffortLevel: String, CaseIterable, Identifiable {
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
  @Environment(ServerAppState.self) private var serverState
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry

  /// Pre-selected provider (set by caller)
  @State var provider: SessionProvider = .claude
  let continuation: SessionContinuation?

  // Shared state
  @State private var selectedPath: String = ""
  @State private var selectedPathIsGit: Bool = true
  @State private var selectedEndpointId: UUID = ServerEndpointSettings.defaultEndpoint.id
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

  init(provider: SessionProvider = .claude, continuation: SessionContinuation? = nil) {
    _provider = State(initialValue: provider)
    self.continuation = continuation
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
    endpointAppState.codexRequiresOpenAIAuth && endpointAppState.codexAccount == nil
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

  private var defaultCodexModel: String {
    if let model = codexModels.first(where: { $0.isDefault && !$0.model.isEmpty })?.model {
      return model
    }
    return codexModels.first(where: { !$0.model.isEmpty })?.model ?? ""
  }

  private var codexModelOptionsSignature: String {
    codexModels.map(\.model).joined(separator: "|")
  }

  private var selectableEndpoints: [ServerEndpoint] {
    let enabled = ServerEndpointSettings.endpoints.filter(\.isEnabled)
    return enabled.isEmpty ? ServerEndpointSettings.endpoints : enabled
  }

  private var endpointAppState: ServerAppState {
    runtimeRegistry.appState(for: selectedEndpointId, fallback: serverState)
  }

  private var endpointStatus: ConnectionStatus {
    runtimeRegistry.connectionStatusByEndpointId[selectedEndpointId]
      ?? runtimeRegistry.connection(for: selectedEndpointId)?.status
      ?? .disconnected
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
      isRemoteConnection: endpointAppState.connection.isRemoteConnection
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
      if let primaryEndpointId = runtimeRegistry.primaryEndpointId,
         selectableEndpoints.contains(where: { $0.id == primaryEndpointId })
      {
        selectedEndpointId = primaryEndpointId
      }
      if let continuation,
         selectableEndpoints.contains(where: { $0.id == continuation.endpointId })
      {
        selectedEndpointId = continuation.endpointId
      }
      normalizeEndpointSelection()
      refreshEndpointData()
      applyContinuationDefaultsIfNeeded()
      syncModelSelections()
    }
    .onChange(of: selectedPath) { _, _ in
      useWorktree = false
      worktreeBranch = ""
      worktreeBaseBranch = ""
      worktreeError = nil
    }
    .onChange(of: selectedEndpointId) { _, _ in
      selectedPath = ""
      resetProviderState()
      normalizeEndpointSelection()
      refreshEndpointData()
      applyContinuationDefaultsIfNeeded()
    }
    .onChange(of: provider) { _, _ in
      resetProviderState()
      refreshEndpointData()
      syncModelSelections()
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

      if provider == .codex, endpointAppState.codexAccount == nil {
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
    HStack(spacing: 0) {
      ForEach(SessionProvider.allCases) { p in
        Button {
          withAnimation(Motion.standard) {
            provider = p
          }
        } label: {
          HStack(spacing: Spacing.sm_) {
            Image(systemName: p.icon)
              .font(.system(size: 10, weight: .semibold))
            Text(p.displayName)
              .font(.system(size: TypeScale.body, weight: .medium))
          }
          .padding(.horizontal, Spacing.lg)
          .padding(.vertical, Spacing.sm)
          .frame(maxWidth: .infinity)
          .foregroundStyle(provider == p ? Color.backgroundSecondary : Color.textTertiary)
          .background(
            provider == p
              ? AnyShapeStyle(p.color)
              : AnyShapeStyle(Color.clear)
          )
        }
        .buttonStyle(.plain)
        #if !os(iOS)
          .onHover { hovering in
            if hovering {
              NSCursor.pointingHand.push()
            } else {
              NSCursor.pop()
            }
          }
        #endif
      }
    }
    .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.ml, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
        .stroke(Color.surfaceBorder, lineWidth: 1)
    )
    .clipShape(RoundedRectangle(cornerRadius: Radius.ml, style: .continuous))
  }

  // MARK: - Header

  private var header: some View {
    #if os(iOS)
      VStack(alignment: .leading, spacing: Spacing.md) {
        HStack(spacing: Spacing.sm) {
          headerIcon

          Text("New Session")
            .font(.system(size: TypeScale.large, weight: .semibold))
            .foregroundStyle(Color.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.9)

          Spacer(minLength: Spacing.sm)

          if provider == .codex, let account = endpointAppState.codexAccount {
            connectedBadge(account)
          }

          closeButton
        }
      }
      .padding(.horizontal, Spacing.lg)
      .padding(.vertical, Spacing.md)
    #else
      HStack(spacing: Spacing.sm) {
        headerIcon

        Text("New Session")
          .font(.system(size: TypeScale.subhead, weight: .semibold))
          .foregroundStyle(Color.textPrimary)

        Spacer()

        if provider == .codex, let account = endpointAppState.codexAccount {
          connectedBadge(account)
        }

        closeButton
      }
      .padding(.horizontal, Spacing.xl)
      .padding(.vertical, Spacing.md)
    #endif
  }

  private var headerIcon: some View {
    Circle()
      .fill(provider.color.opacity(OpacityTier.light))
      .frame(width: 26, height: 26)
      .overlay(
        Image(systemName: "plus.circle.fill")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(provider.color)
      )
      .animation(Motion.standard, value: provider)
  }

  private var closeButton: some View {
    Button {
      dismiss()
    } label: {
      Image(systemName: "xmark.circle.fill")
        .font(.system(size: 18))
        .foregroundStyle(Color.textQuaternary)
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    #if !os(iOS)
      .onHover { hovering in
        if hovering {
          NSCursor.pointingHand.push()
        } else {
          NSCursor.pop()
        }
      }
    #endif
  }

  // MARK: - Auth Gate (Codex only)

  @ViewBuilder
  private func continuationSection(_ continuation: SessionContinuation) -> some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack(alignment: .top, spacing: Spacing.sm) {
        Image(systemName: "arrow.right.circle.fill")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(Color.accent)

        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text("Continue From \(continuation.displayName)")
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(Color.textPrimary)

          Text(continuation.sourceSummary)
            .font(.system(size: TypeScale.caption, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textTertiary)

          Text("This starts a fresh session, then asks the new agent to inspect session `\(continuation.sessionId)` with the OrbitDock CLI for context.")
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      if !selectedEndpointSupportsContinuation {
        Text("Continue from session is limited to the same local OrbitDock server for now. Switch back to the source endpoint or use the normal new-session flow.")
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.statusPermission)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(Spacing.lg)
    .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .stroke(Color.surfaceBorder, lineWidth: 1)
    )
  }

  private var authGateSection: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack(spacing: Spacing.sm) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 11))
          .foregroundStyle(Color.statusPermission)

        Text("Connect your ChatGPT account to create sessions")
          .font(.system(size: TypeScale.body, weight: .medium))
          .foregroundStyle(Color.textSecondary)
      }

      HStack(spacing: Spacing.sm) {
        if endpointAppState.codexLoginInProgress {
          Button {
            endpointAppState.cancelCodexChatgptLogin()
          } label: {
            Label("Cancel", systemImage: "xmark.circle")
              .font(.system(size: TypeScale.body, weight: .semibold))
          }
          .buttonStyle(.bordered)

          HStack(spacing: Spacing.sm) {
            ProgressView()
              .controlSize(.small)
            Text("Waiting for browser…")
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.textTertiary)
          }
        } else {
          Button {
            endpointAppState.startCodexChatgptLogin()
          } label: {
            Label("Sign in with ChatGPT", systemImage: "sparkles")
              .font(.system(size: TypeScale.body, weight: .semibold))
          }
          .buttonStyle(.borderedProminent)
          .tint(Color.accent)
        }
      }

      if let authError = endpointAppState.codexAuthError, !authError.isEmpty {
        Text(authError)
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.statusPermission)
      }
    }
    .padding(Spacing.lg)
    .background(
      Color.statusPermission.opacity(OpacityTier.tint),
      in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .stroke(Color.statusPermission.opacity(OpacityTier.light), lineWidth: 1)
    )
  }

  // MARK: - Endpoint & Directory

  private var endpointSection: some View {
    EndpointSelectorField(
      endpoints: selectableEndpoints,
      statusByEndpointId: runtimeRegistry.connectionStatusByEndpointId,
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
    VStack(alignment: .leading, spacing: 0) {
      modelRow

      Divider()
        .padding(.horizontal, Spacing.lg)

      switch provider {
        case .claude:
          claudePermissionRow

          Divider()
            .padding(.horizontal, Spacing.lg)

          claudeEffortRow

        case .codex:
          codexAutonomyRow
      }
    }
    .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .stroke(Color.surfaceBorder, lineWidth: 1)
    )
  }

  // MARK: - Model Row

  private var modelRow: some View {
    HStack {
      HStack(spacing: Spacing.sm) {
        Image(systemName: "cpu")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Color.textTertiary)
        Text("Model")
          .font(.system(size: TypeScale.body, weight: .medium))
          .foregroundStyle(Color.textSecondary)
      }

      Spacer()

      switch provider {
        case .claude:
          claudeModelPicker

        case .codex:
          codexModelPicker
      }
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.sm)
  }

  @ViewBuilder
  private var claudeModelPicker: some View {
    if useCustomModel {
      TextField("e.g. claude-sonnet-4-5-20250929", text: $customModelInput)
        .textFieldStyle(.roundedBorder)
        .font(.system(size: TypeScale.body, design: .monospaced))
        .frame(maxWidth: 220)
    } else {
      Picker("Model", selection: $claudeModelId) {
        ForEach(claudeModels) { model in
          Text(model.displayName).tag(model.value)
        }
      }
      .pickerStyle(.menu)
      .labelsHidden()
      .fixedSize()
    }

    Button {
      useCustomModel.toggle()
      if !useCustomModel {
        customModelInput = ""
      }
    } label: {
      Text(useCustomModel ? "Picker" : "Custom")
        .font(.system(size: TypeScale.caption, weight: .medium))
        .foregroundStyle(Color.accent)
    }
    .buttonStyle(.plain)
  }

  @ViewBuilder
  private var codexModelPicker: some View {
    if !codexModel.isEmpty {
      Picker("Model", selection: $codexModel) {
        ForEach(codexModels.filter { !$0.model.isEmpty }, id: \.id) { model in
          Text(model.displayName).tag(model.model)
        }
      }
      .pickerStyle(.menu)
      .labelsHidden()
      .fixedSize()
    } else {
      ProgressView()
        .controlSize(.small)
    }
  }

  // MARK: - Claude Permission Row

  private var claudePermissionRow: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack {
        HStack(spacing: Spacing.sm) {
          Image(systemName: selectedPermissionMode.icon)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(selectedPermissionMode.color)
          Text("Permission")
            .font(.system(size: TypeScale.body, weight: .medium))
            .foregroundStyle(Color.textSecondary)
        }

        Spacer()

        CompactClaudePermissionSelector(selection: $selectedPermissionMode)
      }

      // Inline description
      HStack(alignment: .top, spacing: Spacing.sm) {
        Capsule()
          .fill(selectedPermissionMode.color.opacity(0.4))
          .frame(width: 2, height: 20)
          .padding(.top, Spacing.xxs)

        VStack(alignment: .leading, spacing: Spacing.xxs) {
          HStack(spacing: Spacing.sm) {
            Text(selectedPermissionMode.displayName)
              .font(.system(size: TypeScale.body, weight: .semibold))
              .foregroundStyle(selectedPermissionMode.color)

            if selectedPermissionMode.isDefault {
              Text("DEFAULT")
                .font(.system(size: 7, weight: .bold, design: .rounded))
                .foregroundStyle(Color.textSecondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Color.textSecondary.opacity(OpacityTier.light), in: Capsule())
            }
          }

          Text(selectedPermissionMode.description)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.leading, Spacing.lg)
      .animation(Motion.bouncy, value: selectedPermissionMode)
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.sm)
  }

  // MARK: - Claude Effort Row

  private var claudeEffortRow: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack {
        HStack(spacing: Spacing.sm) {
          Image(systemName: selectedEffort.icon)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(selectedEffort.color)
          Text("Effort")
            .font(.system(size: TypeScale.body, weight: .medium))
            .foregroundStyle(Color.textSecondary)
        }

        Spacer()

        Picker("Effort", selection: $selectedEffort) {
          ForEach(ClaudeEffortLevel.allCases) { level in
            Text(level.displayName).tag(level)
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
      }

      HStack(alignment: .top, spacing: Spacing.sm) {
        Capsule()
          .fill(selectedEffort.color.opacity(0.4))
          .frame(width: 2, height: 20)
          .padding(.top, Spacing.xxs)

        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text(selectedEffort.displayName)
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(selectedEffort.color)

          Text(selectedEffort.description)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.leading, Spacing.lg)
      .animation(Motion.bouncy, value: selectedEffort)
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.sm)
  }

  // MARK: - Codex Autonomy Row

  private var codexAutonomyRow: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack {
        HStack(spacing: Spacing.sm) {
          Image(systemName: selectedAutonomy.icon)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(selectedAutonomy.color)
          Text("Autonomy")
            .font(.system(size: TypeScale.body, weight: .medium))
            .foregroundStyle(Color.textSecondary)
        }

        Spacer()

        CompactAutonomySelector(selection: $selectedAutonomy)
      }

      // Inline description
      HStack(alignment: .top, spacing: Spacing.sm) {
        Capsule()
          .fill(selectedAutonomy.color.opacity(0.4))
          .frame(width: 2, height: 20)
          .padding(.top, Spacing.xxs)

        VStack(alignment: .leading, spacing: Spacing.xxs) {
          HStack(spacing: Spacing.sm) {
            Text(selectedAutonomy.displayName)
              .font(.system(size: TypeScale.body, weight: .semibold))
              .foregroundStyle(selectedAutonomy.color)

            if selectedAutonomy.isDefault {
              Text("DEFAULT")
                .font(.system(size: 7, weight: .bold, design: .rounded))
                .foregroundStyle(Color.textSecondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Color.textSecondary.opacity(OpacityTier.light), in: Capsule())
            }
          }

          Text(selectedAutonomy.description)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textTertiary)
            .fixedSize(horizontal: false, vertical: true)

          // Metadata badges
          HStack(spacing: Spacing.sm) {
            HStack(spacing: Spacing.xxs) {
              Image(
                systemName: selectedAutonomy.approvalBehavior
                  .contains("Never") ? "hand.raised.slash" : "hand.raised.fill"
              )
              .font(.system(size: 8))
              Text(selectedAutonomy.approvalBehavior)
                .font(.system(size: TypeScale.micro, weight: .medium))
            }

            HStack(spacing: Spacing.xxs) {
              Image(systemName: selectedAutonomy.isSandboxed ? "shield.fill" : "shield.slash")
                .font(.system(size: 8))
              Text(selectedAutonomy.isSandboxed ? "Sandboxed" : "No sandbox")
                .font(.system(size: TypeScale.micro, weight: .medium))
            }
            .foregroundStyle(
              selectedAutonomy.isSandboxed ? Color.textQuaternary : Color.autonomyOpen.opacity(0.7))
          }
          .foregroundStyle(Color.textQuaternary)
          .padding(.top, Spacing.xxs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.leading, Spacing.lg)
      .animation(Motion.bouncy, value: selectedAutonomy)
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.sm)
  }

  // MARK: - Tool Restrictions Card (Claude only)

  private var toolRestrictionsCard: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(Motion.bouncy) {
          showToolConfig.toggle()
        }
      } label: {
        HStack(spacing: Spacing.sm) {
          Circle()
            .fill(Color.textQuaternary.opacity(OpacityTier.light))
            .frame(width: 20, height: 20)
            .overlay(
              Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.textTertiary)
            )

          Text("Tool Restrictions")
            .font(.system(size: TypeScale.body, weight: .medium))
            .foregroundStyle(Color.textSecondary)

          Text("OPTIONAL")
            .font(.system(size: 7, weight: .bold, design: .rounded))
            .foregroundStyle(Color.textTertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Color.textTertiary.opacity(OpacityTier.light), in: Capsule())

          Spacer()

          Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color.textQuaternary)
            .rotationEffect(.degrees(showToolConfig ? 90 : 0))
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      #if !os(iOS)
        .onHover { hovering in
          if hovering {
            NSCursor.pointingHand.push()
          } else {
            NSCursor.pop()
          }
        }
      #endif

      if showToolConfig {
        Divider()
          .padding(.horizontal, Spacing.lg)

        VStack(alignment: .leading, spacing: Spacing.md) {
          VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
              Text("Allowed Tools")
                .font(.system(size: TypeScale.caption, weight: .semibold))
                .foregroundStyle(Color.textSecondary)
              Text("•")
                .font(.system(size: TypeScale.micro))
                .foregroundStyle(Color.textQuaternary)
              Text("Comma-separated list")
                .font(.system(size: TypeScale.micro))
                .foregroundStyle(Color.textTertiary)
            }
            TextField("e.g. Read, Glob, Bash(git:*)", text: $allowedToolsText)
              .textFieldStyle(.roundedBorder)
              .font(.system(size: TypeScale.caption, design: .monospaced))
          }

          VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
              Text("Disallowed Tools")
                .font(.system(size: TypeScale.caption, weight: .semibold))
                .foregroundStyle(Color.textSecondary)
              Text("•")
                .font(.system(size: TypeScale.micro))
                .foregroundStyle(Color.textQuaternary)
              Text("Comma-separated list")
                .font(.system(size: TypeScale.micro))
                .foregroundStyle(Color.textTertiary)
            }
            TextField("e.g. Write, Edit", text: $disallowedToolsText)
              .textFieldStyle(.roundedBorder)
              .font(.system(size: TypeScale.caption, design: .monospaced))
          }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .stroke(Color.surfaceBorder, lineWidth: 1)
    )
  }

  // MARK: - Footer

  private var footer: some View {
    #if os(iOS)
      VStack(alignment: .leading, spacing: Spacing.md) {
        if provider == .codex, endpointAppState.codexAccount != nil {
          signOutButton
        }

        HStack(spacing: Spacing.sm) {
          cancelButton
            .frame(maxWidth: .infinity)
          launchButton
            .frame(maxWidth: .infinity)
        }
      }
      .padding(.horizontal, Spacing.lg)
      .padding(.top, Spacing.md)
      .padding(.bottom, Spacing.lg)
    #else
      HStack(spacing: Spacing.md) {
        if provider == .codex, endpointAppState.codexAccount != nil {
          signOutButton
        }

        Spacer()

        cancelButton
        launchButton
      }
      .padding(.horizontal, Spacing.xl)
      .padding(.vertical, Spacing.md)
    #endif
  }

  private var signOutButton: some View {
    Button {
      endpointAppState.logoutCodexAccount()
    } label: {
      Text("Sign Out")
        .font(.system(size: TypeScale.caption, weight: .medium))
        .foregroundStyle(Color.textQuaternary)
    }
    .buttonStyle(.plain)
    #if !os(iOS)
      .onHover { hovering in
        if hovering {
          NSCursor.pointingHand.push()
        } else {
          NSCursor.pop()
        }
      }
    #endif
  }

  private var cancelButton: some View {
    Button("Cancel") {
      dismiss()
    }
    .buttonStyle(.bordered)
    .tint(Color.textTertiary)
    #if os(iOS)
      .controlSize(.large)
    #else
      .keyboardShortcut(.escape, modifiers: [])
    #endif
  }

  private var launchButton: some View {
    Button {
      createSession()
    } label: {
      if isCreating {
        HStack(spacing: Spacing.sm) {
          ProgressView()
            .controlSize(.small)
          Text("Launch")
            .font(.system(size: TypeScale.body, weight: .semibold))
        }
        .frame(minWidth: 90)
      } else {
        HStack(spacing: Spacing.sm) {
          Image(systemName: "paperplane.fill")
            .font(.system(size: 12, weight: .semibold))
          Text("Launch")
            .font(.system(size: TypeScale.body, weight: .semibold))
        }
        .frame(minWidth: 90)
      }
    }
    .buttonStyle(.borderedProminent)
    .tint(provider.color)
    .disabled(!canCreateSession)
    #if os(iOS)
      .controlSize(.large)
    #else
      .keyboardShortcut(.return, modifiers: .command)
    #endif
  }

  // MARK: - Helpers

  private func connectedBadge(_ account: ServerCodexAccount) -> some View {
    HStack(spacing: Spacing.sm) {
      switch account {
        case .apiKey:
          HStack(spacing: Spacing.xs) {
            Circle()
              .fill(Color.providerCodex)
              .frame(width: 6, height: 6)
            Text("API Key")
              .font(.system(size: TypeScale.caption, weight: .medium))
              .foregroundStyle(Color.textTertiary)
          }

        case let .chatgpt(email, planType):
          HStack(spacing: Spacing.xs) {
            Circle()
              .fill(Color.providerCodex)
              .frame(width: 6, height: 6)

            if let email {
              Text(email)
                .font(.system(size: TypeScale.caption, weight: .medium))
                .foregroundStyle(Color.textTertiary)
                .lineLimit(1)
            }

            if let planType {
              Text(planType.uppercased())
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(Color.providerCodex)
                .padding(.horizontal, 5)
                .padding(.vertical, Spacing.xxs)
                .background(Color.providerCodex.opacity(OpacityTier.light), in: Capsule())
            }
          }
      }
    }
  }

  private func errorBanner(_ message: String) -> some View {
    HStack(spacing: Spacing.sm) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 11))
        .foregroundStyle(Color.statusPermission)
      Text(message)
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.textSecondary)
    }
    .padding(Spacing.md)
    .background(Color.statusPermission.opacity(OpacityTier.tint), in: RoundedRectangle(cornerRadius: Radius.md))
  }

  private func parseToolList(_ text: String) -> [String] {
    text.split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  // MARK: - Actions

  private func normalizeEndpointSelection() {
    guard !selectableEndpoints.isEmpty else { return }
    if selectableEndpoints.contains(where: { $0.id == selectedEndpointId }) {
      return
    }
    if let primaryEndpointId = runtimeRegistry.primaryEndpointId,
       selectableEndpoints.contains(where: { $0.id == primaryEndpointId })
    {
      selectedEndpointId = primaryEndpointId
      return
    }
    selectedEndpointId = selectableEndpoints.first(where: \.isDefault)?.id
      ?? selectableEndpoints.first?.id
      ?? selectedEndpointId
  }

  private func refreshEndpointData() {
    // Always refresh both providers so models are ready when switching
    endpointAppState.refreshClaudeModels()
    endpointAppState.refreshCodexModels()
    endpointAppState.refreshCodexAccount()
  }

  private func resetProviderState() {
    // Reset provider-specific state when switching
    claudeModelId = ""
    customModelInput = ""
    useCustomModel = false
    selectedPermissionMode = .default
    allowedToolsText = ""
    disallowedToolsText = ""
    showToolConfig = false
    selectedEffort = .default
    codexModel = ""
    selectedAutonomy = .autonomous
    codexErrorMessage = nil
  }

  private func syncModelSelections() {
    syncClaudeModelSelection()
    syncCodexModelSelection()
  }

  private func syncClaudeModelSelection() {
    if claudeModels.isEmpty {
      useCustomModel = true
    } else if claudeModelId.isEmpty || !claudeModels.contains(where: { $0.value == claudeModelId }) {
      claudeModelId = claudeModels.first?.value ?? ""
      useCustomModel = false
    }
  }

  private func syncCodexModelSelection() {
    if codexModel.isEmpty || !codexModels.contains(where: { $0.model == codexModel }) {
      codexModel = defaultCodexModel
    }
  }

  private func initGitAndEnableWorktree() {
    guard let connection = runtimeRegistry.connection(for: selectedEndpointId) else { return }
    isCreating = true
    Task { @MainActor in
      defer { isCreating = false }
      do {
        try await connection.gitInit(path: selectedPath)
        selectedPathIsGit = true
        useWorktree = true
      } catch {
        worktreeError = "Failed to initialize git: \(error.localizedDescription)"
      }
    }
  }

  private func createSession() {
    guard !selectedPath.isEmpty else { return }

    let branch = worktreeBranch.trimmingCharacters(in: .whitespaces)

    if useWorktree, !branch.isEmpty {
      createSessionWithWorktree(branch: branch)
    } else {
      createSessionDirect()
    }
  }

  private func createSessionWithWorktree(branch: String) {
    isCreating = true
    worktreeError = nil
    guard let connection = runtimeRegistry.connection(for: selectedEndpointId) else { return }
    Task { @MainActor in
      do {
        let baseBranch = worktreeBaseBranch.trimmingCharacters(in: .whitespaces)
        let worktree = try await connection.createWorktreeAsync(
          repoPath: selectedPath,
          branchName: branch,
          baseBranch: baseBranch.isEmpty ? nil : baseBranch
        )
        launchSession(cwd: worktree.worktreePath)
        dismiss()
      } catch {
        isCreating = false
        worktreeError = error.localizedDescription
      }
    }
  }

  private func createSessionDirect() {
    launchSession(cwd: selectedPath)
    dismiss()
  }

  private func launchSession(cwd: String) {
    switch provider {
      case .claude:
        endpointAppState.createClaudeSession(
          cwd: cwd,
          model: resolvedClaudeModel,
          permissionMode: selectedPermissionMode == .default ? nil : selectedPermissionMode.rawValue,
          allowedTools: parseToolList(allowedToolsText),
          disallowedTools: parseToolList(disallowedToolsText),
          effort: selectedEffort.serialized,
          initialPrompt: continuationPrompt
        )
      case .codex:
        endpointAppState.createSession(
          cwd: cwd,
          model: codexModel,
          approvalPolicy: selectedAutonomy.approvalPolicy,
          sandboxMode: selectedAutonomy.sandboxMode,
          initialPrompt: continuationPrompt
        )
    }
  }

  private func applyContinuationDefaultsIfNeeded() {
    guard let continuation else { return }
    guard continuation.endpointId == selectedEndpointId else { return }
    guard selectedPath.isEmpty else { return }

    selectedPath = continuation.projectPath
    selectedPathIsGit = continuation.hasGitRepository
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
  NewSessionSheet()
    .environment(ServerAppState())
    .environment(ServerRuntimeRegistry.shared)
}
