import SwiftUI

struct NewSessionConfigurationCard: View {
  enum Style {
    case card
    case embedded
  }

  @State private var showCodexAdvancedSettings = false

  let style: Style
  let provider: SessionProvider
  let claudeModels: [ServerClaudeModelOption]
  let codexModels: [ServerCodexModelOption]
  @Binding var claudeModelId: String
  @Binding var customModelInput: String
  @Binding var useCustomModel: Bool
  @Binding var selectedPermissionMode: ClaudePermissionMode
  @Binding var allowBypassPermissions: Bool
  @Binding var selectedEffort: ClaudeEffortLevel
  @Binding var codexModel: String
  @Binding var codexConfigMode: ServerCodexConfigMode
  @Binding var codexConfigProfile: String
  @Binding var codexModelProvider: String
  @Binding var selectedAutonomy: AutonomyLevel
  @Binding var codexCollaborationMode: CodexCollaborationMode
  @Binding var codexMultiAgentEnabled: Bool
  @Binding var codexPersonality: CodexPersonalityPreset
  @Binding var codexServiceTier: CodexServiceTierPreset
  @Binding var codexInstructions: String
  let hasSelectedPath: Bool
  let codexCatalogRequiresProjectPath: Bool
  let codexCatalog: SessionsClient.CodexConfigCatalogResponse?
  let codexCatalogLoading: Bool
  let codexCatalogError: String?
  let codexScopedModelProvider: String?
  let codexScopedModelsLoading: Bool
  let codexScopedModelError: String?
  let onInspectCodexConfig: (() -> Void)?
  let onManageCodexConfig: (() -> Void)?

  private var currentCodexModelOption: ServerCodexModelOption? {
    let normalizedModel = codexModel.trimmingCharacters(in: .whitespacesAndNewlines)
    if !normalizedModel.isEmpty {
      return codexModels.first(where: { $0.model == normalizedModel })
    }
    return codexModels.first(where: \.isDefault) ?? codexModels.first
  }

  private var availableCodexCollaborationModes: [CodexCollaborationMode] {
    CodexCollaborationMode.supportedCases(from: currentCodexModelOption)
  }

  private var availableCodexServiceTiers: [CodexServiceTierPreset] {
    CodexServiceTierPreset.supportedCases(from: currentCodexModelOption)
  }

  private var codexSupportsMultiAgent: Bool {
    currentCodexModelOption?.supportsMultiAgent ?? true
  }

  private var codexMultiAgentIsExperimental: Bool {
    currentCodexModelOption?.multiAgentIsExperimental ?? true
  }

  private var codexSupportsPersonality: Bool {
    currentCodexModelOption?.supportsPersonality ?? true
  }

  private var codexSupportsDeveloperInstructions: Bool {
    currentCodexModelOption?.supportsDeveloperInstructions ?? true
  }

  private var profileOptions: [SessionsClient.CodexConfigProfileSummary] {
    codexCatalog?.profiles.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } ?? []
  }

  private var providerOptions: [SessionsClient.CodexProviderSummary] {
    codexCatalog?.providers.sorted {
      ($0.displayName ?? $0.id).localizedCaseInsensitiveCompare($1.displayName ?? $1.id) == .orderedAscending
    } ?? []
  }

  private var selectedProfileSummary: SessionsClient.CodexConfigProfileSummary? {
    profileOptions.first(where: { $0.name == codexConfigProfile })
  }

  private var selectedProviderSummary: SessionsClient.CodexProviderSummary? {
    providerOptions.first(where: { $0.id == codexModelProvider })
  }

  private var codexModelDisplayName: String {
    if let option = currentCodexModelOption {
      return option.displayName
    }
    let normalizedModel = codexModel.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalizedModel.isEmpty ? "Choose model" : normalizedModel
  }

  private var usesCustomCodexConfig: Bool {
    codexConfigMode == .custom
  }

  private var codexScopedModelNotice: String? {
    guard usesCustomCodexConfig,
          let provider = codexScopedModelProvider?.trimmingCharacters(in: .whitespacesAndNewlines),
          !provider.isEmpty
    else {
      return nil
    }

    if codexScopedModelsLoading {
      return "Loading provider-scoped models for \(provider)…"
    }

    if let codexScopedModelError, !codexScopedModelError.isEmpty {
      return
        "Couldn’t load models for \(provider). OrbitDock is hiding the generic Codex list here so you only pick provider-compatible models. You can still type a model ID manually."
    }

    if codexModels.isEmpty {
      return
        "No suggested models were returned for \(provider). OrbitDock is hiding the generic Codex list here so you don’t pick an incompatible model."
    }

    return nil
  }

  private var codexResolvedProfileLabel: String {
    switch codexConfigMode {
      case .inherit:
        codexCatalog?.effectiveSettings?.configProfile ?? "Folder default"
      case .profile:
        selectedProfileSummary?.name ?? "Saved profile"
      case .custom:
        "Custom session"
    }
  }

  private var codexResolvedProviderLabel: String {
    switch codexConfigMode {
      case .inherit:
        codexCatalog?.effectiveSettings?.modelProvider ?? "Resolved by Codex"
      case .profile:
        selectedProfileSummary?.modelProvider ?? "From selected profile"
      case .custom:
        selectedProviderSummary?.displayName ?? selectedProviderSummary?.id ?? "Choose provider"
    }
  }

  private var codexResolvedModelLabel: String {
    switch codexConfigMode {
      case .inherit:
        codexCatalog?.effectiveSettings?.model ?? "Resolved by Codex"
      case .profile:
        selectedProfileSummary?.model ?? "From selected profile"
      case .custom:
        codexModelDisplayName
    }
  }

  var body: some View {
    let content = VStack(alignment: .leading, spacing: style == .embedded ? Spacing.md : 0) {
      switch provider {
        case .claude:
          if style == .card {
            configurationHeader

            Divider()
              .padding(.horizontal, Spacing.lg)
          }

          modelRow

          claudeControlsCluster

          claudeBypassRow

        case .codex:
          if style == .card {
            configurationHeader

            Divider()
              .padding(.horizontal, Spacing.lg)
          }

          codexConfigurationModeRow

          if usesCustomCodexConfig {
            codexCustomIdentitySection

            codexBehaviorCluster

            codexAdvancedSettingsSection
          } else {
            codexResolvedValuesSection
          }
      }
    }

    switch style {
      case .card:
        content
          .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
              .stroke(Color.surfaceBorder, lineWidth: 1)
          )
          .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
      case .embedded:
        content
    }
  }

  private var configurationHeader: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(alignment: .center, spacing: Spacing.sm) {
        Circle()
          .fill(headerTint.opacity(OpacityTier.light))
          .frame(width: 28, height: 28)
          .overlay(
            Image(systemName: headerIcon)
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(headerTint)
          )

        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text(headerTitle)
            .font(.system(size: TypeScale.subhead, weight: .semibold))
            .foregroundStyle(Color.textPrimary)

          Text(headerSubtitle)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer()
      }

      codexStatusStrip
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.top, Spacing.lg)
    .padding(.bottom, Spacing.md)
  }

  private var headerIcon: String {
    switch provider {
      case .claude:
        "slider.horizontal.3"
      case .codex:
        "slider.horizontal.3"
    }
  }

  private var headerTint: Color {
    switch provider {
      case .claude:
        .providerClaude
      case .codex:
        .providerCodex
    }
  }

  private var headerTitle: String {
    switch provider {
      case .claude:
        "Session Behavior"
      case .codex:
        "Session Behavior"
    }
  }

  private var headerSubtitle: String {
    switch provider {
      case .claude:
        "Pick the model, permission posture, and reasoning effort before launch."
      case .codex:
        "Choose a folder when you want Codex to resolve project defaults, or jump straight to a saved profile or custom launch."
    }
  }

  private var codexStatusStrip: some View {
    HStack(spacing: Spacing.sm) {
      if provider == .codex {
        codexHeaderBadge(
          title: codexConfigMode == .inherit ? "Inherited" : codexConfigMode == .profile ? "Saved Profile" :
            "Custom Session",
          tint: Color.providerCodex
        )

        if let displayName = currentCodexModelOption?.displayName {
          codexHeaderBadge(title: displayName, tint: Color.accent)
        }
      } else {
        codexHeaderBadge(title: claudeModelId.isEmpty ? "Model Pending" : claudeModelId, tint: Color.providerClaude)
        codexHeaderBadge(title: selectedPermissionMode.displayName, tint: selectedPermissionMode.color)
      }

      Spacer(minLength: Spacing.sm)
    }
  }

  private func codexHeaderBadge(title: String, tint: Color) -> some View {
    Text(title)
      .font(.system(size: TypeScale.micro, weight: .semibold))
      .foregroundStyle(tint)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.gap)
      .background(tint.opacity(OpacityTier.light), in: Capsule())
      .overlay(
        Capsule()
          .stroke(tint.opacity(OpacityTier.medium), lineWidth: 1)
      )
  }

  private var codexConfigurationModeRow: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      codexModeSelector

      if codexConfigMode == .profile {
        HStack(spacing: Spacing.sm) {
          Picker("Profile", selection: $codexConfigProfile) {
            Text(profileOptions.isEmpty ? "No profiles found" : "Select a profile").tag("")
            ForEach(profileOptions) { profile in
              Text(profile.name).tag(profile.name)
            }
          }
          .pickerStyle(.menu)
          .disabled(profileOptions.isEmpty)

          Spacer()
        }
      }

      if provider == .codex, !hasSelectedPath, codexConfigMode == .inherit {
        codexLaunchHintCard(
          title: "Choose a workspace first",
          detail: "OrbitDock needs a folder to resolve Codex defaults for that project.",
          tint: .statusQuestion,
          icon: "folder.badge.questionmark"
        )
      }

      if provider == .codex, !hasSelectedPath, codexCatalogRequiresProjectPath {
        codexLaunchHintCard(
          title: "Older server needs a folder",
          detail: "Restart the server to enable global profile browsing.",
          tint: .feedbackCaution,
          icon: "arrow.triangle.2.circlepath"
        )
      }

      if let codexCatalogError, !codexCatalogError.isEmpty {
        Text(codexCatalogError)
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.feedbackNegative)
          .fixedSize(horizontal: false, vertical: true)
      } else if codexCatalogLoading {
        HStack(spacing: Spacing.sm) {
          ProgressView()
            .controlSize(.small)
          Text("Loading profiles…")
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textTertiary)
        }
      }

      codexActionLinks
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.md)
    .onChange(of: codexConfigMode) { _, newValue in
      switch newValue {
        case .inherit:
          codexModel = ""
          codexConfigProfile = ""
          codexModelProvider = ""
        case .profile:
          codexModel = ""
          codexModelProvider = ""
          if codexConfigProfile.isEmpty {
            codexConfigProfile = profileOptions.first?.name ?? ""
          }
        case .custom:
          codexConfigProfile = ""
          if codexModel.isEmpty {
            codexModel = currentCodexModelOption?.model
              ?? codexModels.first(where: \.isDefault)?.model
              ?? codexModels.first(where: { !$0.model.isEmpty })?.model
              ?? ""
          }
          if codexModelProvider.isEmpty {
            codexModelProvider = providerOptions.first?.id ?? ""
          }
      }
    }
  }

  private var codexActionLinks: some View {
    HStack(spacing: Spacing.lg) {
      if let onManageCodexConfig {
        Button {
          onManageCodexConfig()
        } label: {
          HStack(spacing: Spacing.xs) {
            Image(systemName: "folder.badge.gearshape")
              .font(.system(size: 10, weight: .medium))
            Text("Manage")
              .font(.system(size: TypeScale.caption, weight: .medium))
          }
          .foregroundStyle(Color.textTertiary)
        }
        .buttonStyle(.plain)
        .platformCursorOnHover()
      }

      if let onInspectCodexConfig {
        Button {
          onInspectCodexConfig()
        } label: {
          HStack(spacing: Spacing.xs) {
            Image(systemName: "doc.text.magnifyingglass")
              .font(.system(size: 10, weight: .medium))
            Text("Inspect")
              .font(.system(size: TypeScale.caption, weight: .medium))
          }
          .foregroundStyle(Color.accent)
        }
        .buttonStyle(.plain)
        .platformCursorOnHover()
      }

      Spacer()
    }
  }

  private var codexModeSelector: some View {
    HStack(spacing: Spacing.xs) {
      codexModeButton(title: "Folder", mode: .inherit)
      codexModeButton(title: "Profile", mode: .profile)
      codexModeButton(title: "Custom", mode: .custom)
    }
    .padding(Spacing.xxs)
    .background(Color.backgroundSecondary, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .stroke(Color.surfaceBorder.opacity(OpacityTier.light), lineWidth: 1)
    )
  }

  private func codexModeButton(title: String, mode: ServerCodexConfigMode) -> some View {
    let isSelected = codexConfigMode == mode
    return Button {
      codexConfigMode = mode
    } label: {
      Text(title)
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(isSelected ? Color.backgroundPrimary : Color.textSecondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.sm)
        .background(
          RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .fill(isSelected ? Color.providerCodex : Color.clear)
        )
    }
    .buttonStyle(.plain)
  }


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
    if codexConfigMode == .inherit {
      Text("From Codex config")
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(Color.textTertiary)
    } else if codexConfigMode == .profile {
      Text(selectedProfileSummary?.model ?? "From selected profile")
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(Color.textTertiary)
    } else {
      VStack(alignment: .trailing, spacing: Spacing.xs) {
        TextField("qwen/qwen3-coder-next", text: $codexModel)
          .textFieldStyle(.roundedBorder)
          .font(.system(size: TypeScale.body, design: .monospaced))
          .frame(maxWidth: 240)

        if !codexModels.isEmpty {
          Picker("Suggested model", selection: $codexModel) {
            Text("Suggested models").tag("")
            ForEach(codexModels.filter { !$0.model.isEmpty }, id: \.id) { model in
              Text(model.displayName).tag(model.model)
            }
          }
          .pickerStyle(.menu)
          .labelsHidden()
          .fixedSize()
        }
      }
    }
  }

  // MARK: - Claude Controls Cluster (Permission + Effort side by side)

  private var claudeControlsCluster: some View {
    HStack(alignment: .top, spacing: Spacing.md) {
      claudePermissionCluster
      claudeEffortCluster
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.sm)
  }

  private var claudePermissionCluster: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("PERMISSIONS")
        .font(.system(size: TypeScale.micro, weight: .semibold))
        .foregroundStyle(Color.textTertiary)
        .textCase(.uppercase)
        .tracking(0.5)

      CompactClaudePermissionSelector(selection: $selectedPermissionMode)

      HStack(spacing: Spacing.sm_) {
        Capsule()
          .fill(selectedPermissionMode.color)
          .frame(width: EdgeBar.width, height: 14)

        Text(selectedPermissionMode.displayName)
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(selectedPermissionMode.color)
      }
      .animation(Motion.bouncy, value: selectedPermissionMode)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(Spacing.md)
    .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .stroke(Color.surfaceBorder.opacity(OpacityTier.light), lineWidth: 1)
    )
  }

  private var claudeEffortCluster: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("EFFORT")
        .font(.system(size: TypeScale.micro, weight: .semibold))
        .foregroundStyle(Color.textTertiary)
        .textCase(.uppercase)
        .tracking(0.5)

      Picker("Effort", selection: $selectedEffort) {
        ForEach(ClaudeEffortLevel.allCases) { level in
          Text(level.displayName).tag(level)
        }
      }
      .pickerStyle(.menu)
      .labelsHidden()
      .frame(maxWidth: .infinity, alignment: .leading)

      HStack(spacing: Spacing.sm_) {
        Capsule()
          .fill(selectedEffort.color)
          .frame(width: EdgeBar.width, height: 14)

        Text(selectedEffort.displayName)
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(selectedEffort.color)
      }
      .animation(Motion.bouncy, value: selectedEffort)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(Spacing.md)
    .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .stroke(Color.surfaceBorder.opacity(OpacityTier.light), lineWidth: 1)
    )
  }


  private func codexLaunchHintCard(title: String, detail: String, tint: Color, icon: String) -> some View {
    HStack(alignment: .top, spacing: Spacing.sm) {
      Image(systemName: icon)
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(tint)
        .frame(width: 18, height: 18)

      VStack(alignment: .leading, spacing: Spacing.xxs) {
        Text(title)
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textPrimary)
        Text(detail)
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textTertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(Spacing.md)
    .background(tint.opacity(OpacityTier.tint), in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .stroke(tint.opacity(OpacityTier.light), lineWidth: 1)
    )
  }

  private var codexResolvedValuesSection: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: Spacing.sm) {
        codexResolvedValueCard(title: "Source", value: codexResolvedProfileLabel, tint: Color.providerCodex)
        codexResolvedValueCard(title: "Provider", value: codexResolvedProviderLabel, tint: Color.textSecondary)
        codexResolvedValueCard(title: "Model", value: codexResolvedModelLabel, tint: Color.accent)
      }

      VStack(alignment: .leading, spacing: Spacing.sm) {
        codexResolvedValueCard(title: "Source", value: codexResolvedProfileLabel, tint: Color.providerCodex)
        codexResolvedValueCard(title: "Provider", value: codexResolvedProviderLabel, tint: Color.textSecondary)
        codexResolvedValueCard(title: "Model", value: codexResolvedModelLabel, tint: Color.accent)
      }
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.md)
  }

  private func codexResolvedValueCard(title: String, value: String, tint: Color) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(title)
        .font(.system(size: TypeScale.micro, weight: .semibold))
        .foregroundStyle(Color.textTertiary)
        .textCase(.uppercase)
        .tracking(0.5)

      Text(value)
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(tint)
        .lineLimit(2)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(Spacing.md)
    .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .stroke(Color.surfaceBorder.opacity(OpacityTier.light), lineWidth: 1)
    )
  }

  private var codexCustomIdentitySection: some View {
    HStack(alignment: .top, spacing: Spacing.md) {
      codexProviderCluster
      codexModelCluster
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.sm)
  }

  private var codexProviderCluster: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("PROVIDER")
        .font(.system(size: TypeScale.micro, weight: .semibold))
        .foregroundStyle(Color.textTertiary)
        .textCase(.uppercase)
        .tracking(0.5)

      Picker("Provider", selection: $codexModelProvider) {
        Text(providerOptions.isEmpty ? "None found" : "Select").tag("")
        ForEach(providerOptions) { provider in
          Text(provider.displayName ?? provider.id).tag(provider.id)
        }
      }
      .pickerStyle(.menu)
      .labelsHidden()
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(Spacing.md)
    .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .stroke(Color.surfaceBorder.opacity(OpacityTier.light), lineWidth: 1)
    )
  }

  private var codexModelCluster: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("MODEL")
        .font(.system(size: TypeScale.micro, weight: .semibold))
        .foregroundStyle(Color.textTertiary)
        .textCase(.uppercase)
        .tracking(0.5)

      TextField("model-id", text: $codexModel)
        .textFieldStyle(.roundedBorder)
        .font(.system(size: TypeScale.caption, design: .monospaced))

      if !codexModels.isEmpty {
        Picker("Suggested", selection: $codexModel) {
          Text("Suggested").tag("")
          ForEach(codexModels.filter { !$0.model.isEmpty }, id: \.id) { model in
            Text(model.displayName).tag(model.model)
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      if let codexScopedModelNotice {
        codexScopedModelNoticeView(codexScopedModelNotice)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(Spacing.md)
    .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .stroke(Color.surfaceBorder.opacity(OpacityTier.light), lineWidth: 1)
    )
  }

  private func codexScopedModelNoticeView(_ message: String) -> some View {
    HStack(alignment: .top, spacing: Spacing.sm) {
      if codexScopedModelsLoading {
        ProgressView()
          .controlSize(.small)
      } else {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: TypeScale.micro, weight: .semibold))
          .foregroundStyle(Color.feedbackCaution)
      }

      Text(message)
        .font(.system(size: TypeScale.micro))
        .foregroundStyle(Color.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }


  private var claudeBypassRow: some View {
    HStack(alignment: .top, spacing: Spacing.md) {
      HStack(spacing: Spacing.sm) {
        Image(systemName: "bolt.trianglebadge.exclamationmark.fill")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(allowBypassPermissions ? Color.autonomyUnrestricted : Color.textTertiary)
        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text("Allow Bypass Permissions")
            .font(.system(size: TypeScale.body, weight: .medium))
            .foregroundStyle(Color.textSecondary)
          Text("Enables switching to full bypass mode mid-session.")
            .font(.system(size: TypeScale.micro))
            .foregroundStyle(Color.textQuaternary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      Spacer()

      Toggle("", isOn: $allowBypassPermissions)
        .labelsHidden()
        .toggleStyle(.switch)
        .tint(Color.autonomyUnrestricted)
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.sm)
  }


  // MARK: - Codex Behavior Cluster (Autonomy + Collaboration + Workers)

  private var codexBehaviorCluster: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Autonomy
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

        HStack(spacing: Spacing.sm) {
          Capsule()
            .fill(selectedAutonomy.color)
            .frame(width: EdgeBar.width, height: 14)

          Text(selectedAutonomy.displayName)
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(selectedAutonomy.color)

          HStack(spacing: Spacing.xs) {
            HStack(spacing: Spacing.xxs) {
              Image(
                systemName: selectedAutonomy.approvalBehavior
                  .contains("Never") ? "hand.raised.slash" : "hand.raised.fill"
              )
              .font(.system(size: 8))
              Text(selectedAutonomy.approvalBehavior)
                .font(.system(size: TypeScale.micro, weight: .medium))
            }

            Text("·")
              .foregroundStyle(Color.textQuaternary)

            HStack(spacing: Spacing.xxs) {
              Image(systemName: selectedAutonomy.isSandboxed ? "shield.fill" : "shield.slash")
                .font(.system(size: 8))
              Text(selectedAutonomy.isSandboxed ? "Sandboxed" : "No sandbox")
                .font(.system(size: TypeScale.micro, weight: .medium))
            }
            .foregroundStyle(
              selectedAutonomy.isSandboxed ? Color.textQuaternary : Color.autonomyOpen.opacity(0.7)
            )
          }
          .foregroundStyle(Color.textQuaternary)
        }
        .animation(Motion.bouncy, value: selectedAutonomy)
      }
      .padding(Spacing.md)

      Rectangle()
        .fill(Color.surfaceBorder.opacity(OpacityTier.light))
        .frame(height: 1)
        .padding(.horizontal, Spacing.sm)

      // Collaboration
      HStack {
        HStack(spacing: Spacing.sm) {
          Image(systemName: codexCollaborationMode.icon)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(codexCollaborationMode.color)
          Text("Collaboration")
            .font(.system(size: TypeScale.body, weight: .medium))
            .foregroundStyle(Color.textSecondary)

          Capsule()
            .fill(codexCollaborationMode.color)
            .frame(width: EdgeBar.width, height: 14)

          Text(codexCollaborationMode.displayName)
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(codexCollaborationMode.color)
        }
        .animation(Motion.bouncy, value: codexCollaborationMode)

        Spacer()

        Picker("Collaboration", selection: $codexCollaborationMode) {
          ForEach(availableCodexCollaborationModes) { mode in
            Text(mode.displayName).tag(mode)
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
      }
      .padding(Spacing.md)

      Rectangle()
        .fill(Color.surfaceBorder.opacity(OpacityTier.light))
        .frame(height: 1)
        .padding(.horizontal, Spacing.sm)

      // Workers
      HStack(alignment: .center, spacing: Spacing.md) {
        HStack(spacing: Spacing.sm) {
          Image(systemName: codexMultiAgentEnabled ? "person.3.fill" : "person.3")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(codexMultiAgentEnabled ? Color.providerCodex : Color.textTertiary)
          Text("Workers")
            .font(.system(size: TypeScale.body, weight: .medium))
            .foregroundStyle(Color.textSecondary)

          if codexMultiAgentIsExperimental {
            Text("BETA")
              .font(.system(size: 7, weight: .bold, design: .rounded))
              .foregroundStyle(Color.feedbackCaution)
              .padding(.horizontal, 5)
              .padding(.vertical, 1.5)
              .background(Color.feedbackCaution.opacity(OpacityTier.light), in: Capsule())
          }

          Text(codexMultiAgentEnabled ? "Enabled" : "Off")
            .font(.system(size: TypeScale.caption, weight: .medium))
            .foregroundStyle(codexMultiAgentEnabled ? Color.providerCodex : Color.textQuaternary)
        }

        Spacer()

        Toggle("", isOn: $codexMultiAgentEnabled)
          .labelsHidden()
          .toggleStyle(.switch)
          .disabled(!codexSupportsMultiAgent)
      }
      .padding(Spacing.md)
    }
    .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .stroke(Color.surfaceBorder.opacity(OpacityTier.light), lineWidth: 1)
    )
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.sm)
  }

  private var codexAdvancedSettingsSection: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      Button {
        withAnimation(Motion.standard) {
          showCodexAdvancedSettings.toggle()
        }
      } label: {
        HStack(spacing: Spacing.sm) {
          Image(systemName: "slider.horizontal.below.rectangle")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.providerCodex)

          Text("Advanced")
            .font(.system(size: TypeScale.body, weight: .medium))
            .foregroundStyle(Color.textSecondary)

          if !showCodexAdvancedSettings, !codexAdvancedSummary.isEmpty {
            Text(codexAdvancedSummary)
              .font(.system(size: TypeScale.caption, weight: .medium))
              .foregroundStyle(Color.textQuaternary)
              .lineLimit(1)
          }

          Spacer()

          Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color.textQuaternary)
            .rotationEffect(.degrees(showCodexAdvancedSettings ? 90 : 0))
            .animation(Motion.snappy, value: showCodexAdvancedSettings)
        }
      }
      .buttonStyle(.plain)
      .platformCursorOnHover()

      if showCodexAdvancedSettings {
        VStack(alignment: .leading, spacing: Spacing.md) {
          HStack(alignment: .top, spacing: Spacing.md) {
            // Personality cluster
            VStack(alignment: .leading, spacing: Spacing.sm) {
              Text("PERSONALITY")
                .font(.system(size: TypeScale.micro, weight: .semibold))
                .foregroundStyle(Color.textTertiary)
                .textCase(.uppercase)
                .tracking(0.5)

              if codexSupportsPersonality {
                Picker("Personality", selection: $codexPersonality) {
                  ForEach(CodexPersonalityPreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                  }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
              } else {
                Text("Unavailable")
                  .font(.system(size: TypeScale.caption, weight: .medium))
                  .foregroundStyle(Color.textQuaternary)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.md)
            .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .stroke(Color.surfaceBorder.opacity(OpacityTier.light), lineWidth: 1)
            )

            // Service Tier cluster
            VStack(alignment: .leading, spacing: Spacing.sm) {
              Text("SERVICE TIER")
                .font(.system(size: TypeScale.micro, weight: .semibold))
                .foregroundStyle(Color.textTertiary)
                .textCase(.uppercase)
                .tracking(0.5)

              Picker("Service Tier", selection: $codexServiceTier) {
                ForEach(availableCodexServiceTiers) { preset in
                  Text(preset.displayName).tag(preset)
                }
              }
              .pickerStyle(.menu)
              .labelsHidden()
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.md)
            .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .stroke(Color.surfaceBorder.opacity(OpacityTier.light), lineWidth: 1)
            )
          }

          // Instructions
          VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("INSTRUCTIONS")
              .font(.system(size: TypeScale.micro, weight: .semibold))
              .foregroundStyle(Color.textTertiary)
              .textCase(.uppercase)
              .tracking(0.5)

            if codexSupportsDeveloperInstructions {
              ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                  .fill(Color.backgroundCode)
                  .overlay(
                    RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                      .stroke(Color.surfaceBorder.opacity(OpacityTier.light), lineWidth: 1)
                  )

                if codexInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                  Text("House rules, code style, team tone…")
                    .font(.system(size: TypeScale.caption))
                    .foregroundStyle(Color.textQuaternary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                }

                TextEditor(text: $codexInstructions)
                  .font(.system(size: TypeScale.body))
                  .foregroundStyle(Color.textPrimary)
                  .scrollContentBackground(.hidden)
                  .frame(minHeight: 72, maxHeight: 100)
                  .padding(.horizontal, Spacing.sm)
                  .padding(.vertical, Spacing.xs)
              }
            } else {
              Text("Not available for this model.")
                .font(.system(size: TypeScale.caption))
                .foregroundStyle(Color.textQuaternary)
            }
          }
        }
        .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.sm)
  }

  private var codexAdvancedSummary: String {
    var summary: [String] = []

    if codexPersonality != .automatic {
      summary.append(codexPersonality.displayName)
    }
    if codexServiceTier != .automatic {
      summary.append(codexServiceTier.displayName)
    }
    if !codexInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      summary.append("Instructions set")
    }

    return summary.joined(separator: " · ")
  }
}
