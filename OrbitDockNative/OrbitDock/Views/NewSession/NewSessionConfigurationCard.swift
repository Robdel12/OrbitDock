import SwiftUI

struct NewSessionConfigurationCard: View {
  @State private var showCodexAdvancedSettings = false

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
    VStack(alignment: .leading, spacing: 0) {
      switch provider {
        case .claude:
          configurationHeader

          Divider()
            .padding(.horizontal, Spacing.lg)

          modelRow

          Divider()
            .padding(.horizontal, Spacing.lg)

          claudePermissionRow

          claudeBypassRow

          Divider()
            .padding(.horizontal, Spacing.lg)

          claudeEffortRow

        case .codex:
          configurationHeader

          Divider()
            .padding(.horizontal, Spacing.lg)

          codexConfigurationModeRow

          if usesCustomCodexConfig {
            Divider()
              .padding(.horizontal, Spacing.lg)

            codexCustomIdentitySection

            Divider()
              .padding(.horizontal, Spacing.lg)

            codexAutonomyRow

            Divider()
              .padding(.horizontal, Spacing.lg)

            codexCollaborationRow

            Divider()
              .padding(.horizontal, Spacing.lg)

            codexMultiAgentRow

            Divider()
              .padding(.horizontal, Spacing.lg)

            codexAdvancedSettingsSection
          } else {
            Divider()
              .padding(.horizontal, Spacing.lg)

            codexResolvedValuesSection
          }
      }
    }
    .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .stroke(Color.surfaceBorder, lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
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
      VStack(alignment: .leading, spacing: Spacing.xs) {
        HStack(spacing: Spacing.sm) {
          Image(systemName: "point.3.connected.trianglepath.dotted")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.providerCodex)
          Text("Launch Source")
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(Color.textPrimary)
        }

        Text(
          "Decide whether this session should follow the folder's resolved Codex setup, one of your saved profiles, or a one-off custom configuration."
        )
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      codexModeSelector

      if codexConfigMode == .profile {
        Picker("Saved profile", selection: $codexConfigProfile) {
          Text(profileOptions.isEmpty ? "No profiles found" : "Select a profile").tag("")
          ForEach(profileOptions) { profile in
            Text(profile.name).tag(profile.name)
          }
        }
        .pickerStyle(.menu)
        .disabled(profileOptions.isEmpty)
      }

      codexModeSummaryCard(
        title: codexConfigModeSummaryTitle,
        detail: codexConfigModeSummaryDetail
      )

      if provider == .codex, !hasSelectedPath, codexConfigMode == .inherit {
        codexLaunchHintCard(
          title: "Folder mode needs a project",
          detail: "Saved profiles and providers are available now, but OrbitDock needs a folder before it can resolve the effective Codex setup for that project.",
          tint: .statusQuestion,
          icon: "folder.badge.questionmark"
        )
      }

      if provider == .codex, !hasSelectedPath, codexCatalogRequiresProjectPath {
        codexLaunchHintCard(
          title: "Older server still needs a folder",
          detail: "This OrbitDock server is still using the older Codex catalog behavior, so saved profiles will appear after you choose a project. Restart the server to enable global profile browsing.",
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
          Text("Loading Codex profiles and providers…")
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textTertiary)
        }
      }

      HStack(spacing: Spacing.md) {
        if let onManageCodexConfig {
          Button("Manage Profiles & Providers") {
            onManageCodexConfig()
          }
          .buttonStyle(.plain)
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textSecondary)
          .padding(.horizontal, Spacing.sm)
          .padding(.vertical, Spacing.sm_)
          .background(Color.backgroundSecondary, in: Capsule())
          .overlay(
            Capsule()
              .stroke(Color.surfaceBorder.opacity(OpacityTier.light), lineWidth: 1)
          )
        }

        if let onInspectCodexConfig {
          Button("Inspect Codex Config") {
            onInspectCodexConfig()
          }
          .buttonStyle(.plain)
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.accent)
          .padding(.horizontal, Spacing.sm)
          .padding(.vertical, Spacing.sm_)
          .background(Color.accent.opacity(OpacityTier.tint), in: Capsule())
          .overlay(
            Capsule()
              .stroke(Color.accent.opacity(OpacityTier.light), lineWidth: 1)
          )
        }

        Spacer()
      }
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

  private var codexConfigModeSummaryTitle: String {
    switch codexConfigMode {
      case .inherit:
        hasSelectedPath ? "Use the folder's effective Codex config" : "Choose a folder for project defaults"
      case .profile:
        selectedProfileSummary.map { "Use profile \($0.name)" } ?? "Choose a saved Codex profile"
      case .custom:
        "Build a custom session configuration"
    }
  }

  private var codexConfigModeSummaryDetail: String {
    switch codexConfigMode {
      case .inherit:
        hasSelectedPath
          ? "OrbitDock will inherit the effective profile, provider, and model Codex resolves for this folder."
          : "Pick a project folder to resolve its Codex defaults. Saved profiles and custom providers can still be selected before that."
      case .profile:
        selectedProfileSummary.map {
          [
            $0.modelProvider.map { "Provider: \($0)" },
            $0.model.map { "Model: \($0)" },
          ]
          .compactMap { $0 }
          .joined(separator: " • ")
        } ?? profileModePlaceholder
      case .custom:
        "Override the provider, model, and launch-time behavior just for this session."
    }
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

  private var profileModePlaceholder: String {
    if profileOptions.isEmpty {
      if codexCatalogLoading {
        return "Loading your saved Codex profiles."
      }
      return "No saved Codex profiles were returned yet."
    }
    if hasSelectedPath {
      return "Pick one of your saved Codex profiles to use it for this session."
    }
    return "Pick one of your saved Codex profiles now, then choose a folder when you're ready to launch."
  }

  private func codexModeSummary(title: String, detail: String) -> some View {
    HStack(alignment: .top, spacing: Spacing.sm) {
      Capsule()
        .fill(Color.providerCodex.opacity(0.35))
        .frame(width: 2, height: 26)
        .padding(.top, Spacing.xxs)

      VStack(alignment: .leading, spacing: Spacing.xxs) {
        Text(title)
          .font(.system(size: TypeScale.body, weight: .semibold))
          .foregroundStyle(Color.textSecondary)
        Text(detail)
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textTertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func codexModeSummaryCard(title: String, detail: String) -> some View {
    codexModeSummary(title: title, detail: detail)
      .padding(Spacing.md)
      .background(Color.backgroundSecondary, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
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
    VStack(alignment: .leading, spacing: Spacing.md) {
      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text("Resolved Values")
          .font(.system(size: TypeScale.body, weight: .semibold))
          .foregroundStyle(Color.textPrimary)
        Text("This is the launch configuration Codex will use unless you switch to Custom.")
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textTertiary)
      }

      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: Spacing.md) {
          codexResolvedValueCard(title: "Source", value: codexResolvedProfileLabel, tint: Color.providerCodex)
          codexResolvedValueCard(title: "Provider", value: codexResolvedProviderLabel, tint: Color.textSecondary)
          codexResolvedValueCard(title: "Model", value: codexResolvedModelLabel, tint: Color.accent)
        }

        VStack(alignment: .leading, spacing: Spacing.md) {
          codexResolvedValueCard(title: "Source", value: codexResolvedProfileLabel, tint: Color.providerCodex)
          codexResolvedValueCard(title: "Provider", value: codexResolvedProviderLabel, tint: Color.textSecondary)
          codexResolvedValueCard(title: "Model", value: codexResolvedModelLabel, tint: Color.accent)
        }
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
    .background(Color.backgroundSecondary, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .stroke(Color.surfaceBorder.opacity(OpacityTier.light), lineWidth: 1)
    )
  }

  private var codexCustomIdentitySection: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      VStack(alignment: .leading, spacing: Spacing.xs) {
        Text("Custom Identity")
          .font(.system(size: TypeScale.body, weight: .semibold))
          .foregroundStyle(Color.textPrimary)
        Text("Choose the provider and model for this one launch, then tune the runtime behavior below.")
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textTertiary)
      }

      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: Spacing.md) {
          codexPickerCard(
            title: "Provider",
            icon: "network",
            tint: Color.providerCodex
          ) {
            Picker("Provider", selection: $codexModelProvider) {
              Text(providerOptions.isEmpty ? "No providers found" : "Select a provider").tag("")
              ForEach(providerOptions) { provider in
                Text(provider.displayName ?? provider.id).tag(provider.id)
              }
            }
            .pickerStyle(.menu)
            .disabled(providerOptions.isEmpty)
          } description: {
            Text(selectedProviderSummary?.displayName ?? selectedProviderSummary?
              .id ?? "Choose from the providers Codex reports for this environment.")
          }

          codexPickerCard(
            title: "Model",
            icon: "cpu",
            tint: Color.accent
          ) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
              TextField("qwen/qwen3-coder-next", text: $codexModel)
                .textFieldStyle(.roundedBorder)

              if !codexModels.isEmpty {
                Picker("Suggested model", selection: $codexModel) {
                  Text("Suggested models").tag("")
                  ForEach(codexModels.filter { !$0.model.isEmpty }, id: \.id) { model in
                    Text(model.displayName).tag(model.model)
                  }
                }
                .pickerStyle(.menu)
              }
            }
          } description: {
            VStack(alignment: .leading, spacing: Spacing.sm) {
              Text(currentCodexModelOption?
                .description ?? "Enter any Codex model ID, or pick one of the discovered suggestions.")

              if let codexScopedModelNotice {
                codexScopedModelNoticeView(codexScopedModelNotice)
              }
            }
          }
        }

        VStack(alignment: .leading, spacing: Spacing.md) {
          codexPickerCard(
            title: "Provider",
            icon: "network",
            tint: Color.providerCodex
          ) {
            Picker("Provider", selection: $codexModelProvider) {
              Text(providerOptions.isEmpty ? "No providers found" : "Select a provider").tag("")
              ForEach(providerOptions) { provider in
                Text(provider.displayName ?? provider.id).tag(provider.id)
              }
            }
            .pickerStyle(.menu)
            .disabled(providerOptions.isEmpty)
          } description: {
            Text(selectedProviderSummary?.displayName ?? selectedProviderSummary?
              .id ?? "Choose from the providers Codex reports for this environment.")
          }

          codexPickerCard(
            title: "Model",
            icon: "cpu",
            tint: Color.accent
          ) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
              TextField("qwen/qwen3-coder-next", text: $codexModel)
                .textFieldStyle(.roundedBorder)

              if !codexModels.isEmpty {
                Picker("Suggested model", selection: $codexModel) {
                  Text("Suggested models").tag("")
                  ForEach(codexModels.filter { !$0.model.isEmpty }, id: \.id) { model in
                    Text(model.displayName).tag(model.model)
                  }
                }
                .pickerStyle(.menu)
              }
            }
          } description: {
            VStack(alignment: .leading, spacing: Spacing.sm) {
              Text(currentCodexModelOption?
                .description ?? "Enter any Codex model ID, or pick one of the discovered suggestions.")

              if let codexScopedModelNotice {
                codexScopedModelNoticeView(codexScopedModelNotice)
              }
            }
          }
        }
      }
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.md)
  }

  private func codexPickerCard(
    title: String,
    icon: String,
    tint: Color,
    @ViewBuilder control: () -> some View,
    @ViewBuilder description: () -> some View
  ) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(spacing: Spacing.sm) {
        Image(systemName: icon)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(tint)
        Text(title)
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textSecondary)
      }

      control()
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)

      description()
        .font(.system(size: TypeScale.micro))
        .foregroundStyle(Color.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(Spacing.md)
    .background(Color.backgroundSecondary, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
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

  private var customProviderRow: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack {
        HStack(spacing: Spacing.sm) {
          Image(systemName: "network")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.providerCodex)
          Text("Provider")
            .font(.system(size: TypeScale.body, weight: .medium))
            .foregroundStyle(Color.textSecondary)
        }

        Spacer()

        Picker("Provider", selection: $codexModelProvider) {
          Text(providerOptions.isEmpty ? "No providers found" : "Select a provider").tag("")
          ForEach(providerOptions) { provider in
            Text(provider.displayName ?? provider.id).tag(provider.id)
          }
        }
        .pickerStyle(.menu)
        .disabled(providerOptions.isEmpty)
      }

      codexModeSummary(
        title: selectedProviderSummary?.displayName ?? selectedProviderSummary?.id ?? "Custom provider",
        detail: selectedProviderSummary.map {
          [
            $0.wireAPI.map { "API: \($0)" },
            $0.baseURL.map { "Base URL: \($0)" },
            $0.envKey.map { "Key: \($0)" },
          ]
          .compactMap { $0 }
          .joined(separator: " • ")
        } ?? "Choose from the providers Codex reports for this environment."
      )
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.sm)
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
              selectedAutonomy.isSandboxed ? Color.textQuaternary : Color.autonomyOpen.opacity(0.7)
            )
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

  private var codexCollaborationRow: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack {
        HStack(spacing: Spacing.sm) {
          Image(systemName: codexCollaborationMode.icon)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(codexCollaborationMode.color)
          Text("Collaboration")
            .font(.system(size: TypeScale.body, weight: .medium))
            .foregroundStyle(Color.textSecondary)
        }

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

      HStack(alignment: .top, spacing: Spacing.sm) {
        Capsule()
          .fill(codexCollaborationMode.color.opacity(0.4))
          .frame(width: 2, height: 20)
          .padding(.top, Spacing.xxs)

        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text(codexCollaborationMode.displayName)
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(codexCollaborationMode.color)

          Text(codexCollaborationMode.description)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.leading, Spacing.lg)
      .animation(Motion.bouncy, value: codexCollaborationMode)
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.sm)
  }

  private var codexMultiAgentRow: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(alignment: .top, spacing: Spacing.md) {
        HStack(spacing: Spacing.sm) {
          Image(systemName: codexMultiAgentEnabled ? "person.3.fill" : "person.3")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(codexMultiAgentEnabled ? Color.providerCodex : Color.textTertiary)
          Text("Workers")
            .font(.system(size: TypeScale.body, weight: .medium))
            .foregroundStyle(Color.textSecondary)

          if codexMultiAgentIsExperimental {
            Text("EXPERIMENTAL")
              .font(.system(size: 7, weight: .bold, design: .rounded))
              .foregroundStyle(Color.feedbackCaution)
              .padding(.horizontal, 5)
              .padding(.vertical, 1.5)
              .background(Color.feedbackCaution.opacity(OpacityTier.light), in: Capsule())
          }
        }

        Spacer()

        Toggle("", isOn: $codexMultiAgentEnabled)
          .labelsHidden()
          .toggleStyle(.switch)
          .disabled(!codexSupportsMultiAgent)
      }

      HStack(alignment: .top, spacing: Spacing.sm) {
        Capsule()
          .fill((codexMultiAgentEnabled ? Color.providerCodex : Color.textQuaternary).opacity(0.35))
          .frame(width: 2, height: 20)
          .padding(.top, Spacing.xxs)

        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text(codexSupportsMultiAgent
            ? (codexMultiAgentEnabled ? "Worker spawning enabled" : "Single-agent session")
            : "Workers unavailable"
          )
          .font(.system(size: TypeScale.body, weight: .semibold))
          .foregroundStyle(
            codexSupportsMultiAgent
              ? (codexMultiAgentEnabled ? Color.providerCodex : Color.textSecondary)
              : Color.textSecondary
          )

          Text(
            codexSupportsMultiAgent
              ? (
                codexMultiAgentEnabled
                  ? "Let Codex spin up helper workers for parallel research, planning, and follow-up tasks in this session."
                  : "Keep Codex focused in one thread. You can still change this later from the session controls."
              )
              : "This model does not currently advertise worker spawning support to OrbitDock."
          )
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textTertiary)
          .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.leading, Spacing.lg)
      .animation(Motion.bouncy, value: codexMultiAgentEnabled)
    }
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

          VStack(alignment: .leading, spacing: 2) {
            Text("Codex Advanced")
              .font(.system(size: TypeScale.body, weight: .semibold))
              .foregroundStyle(Color.textPrimary)
            Text(codexAdvancedSummary)
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.textTertiary)
              .lineLimit(2)
          }

          Spacer()

          Image(systemName: showCodexAdvancedSettings ? "chevron.up" : "chevron.down")
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textQuaternary)
        }
      }
      .buttonStyle(.plain)

      if showCodexAdvancedSettings {
        VStack(alignment: .leading, spacing: Spacing.md) {
          HStack(alignment: .top, spacing: Spacing.md) {
            codexAdvancedPickerCard(
              title: "Personality",
              icon: codexPersonality.icon,
              tint: codexPersonality.color
            ) {
              if codexSupportsPersonality {
                Picker("Personality", selection: $codexPersonality) {
                  ForEach(CodexPersonalityPreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                  }
                }
                .pickerStyle(.menu)
                .labelsHidden()
              } else {
                Text("Unavailable")
                  .font(.system(size: TypeScale.body, weight: .semibold))
                  .foregroundStyle(Color.textQuaternary)
              }
            } description: {
              Text(
                codexSupportsPersonality
                  ? codexPersonality.description
                  : "This model does not currently expose personality overrides through OrbitDock."
              )
            }

            codexAdvancedPickerCard(
              title: "Service Tier",
              icon: codexServiceTier.icon,
              tint: codexServiceTier.color
            ) {
              Picker("Service Tier", selection: $codexServiceTier) {
                ForEach(availableCodexServiceTiers) { preset in
                  Text(preset.displayName).tag(preset)
                }
              }
              .pickerStyle(.menu)
              .labelsHidden()
            } description: {
              Text(codexServiceTier.description)
            }
          }

          VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
              Image(systemName: "text.append")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accent)
              Text("Durable Instructions")
                .font(.system(size: TypeScale.body, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            }

            if codexSupportsDeveloperInstructions {
              ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                  .fill(Color.backgroundSecondary)
                  .overlay(
                    RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                      .stroke(Color.surfaceBorder, lineWidth: 1)
                  )

                if codexInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                  Text("Persistent guidance for the whole session, like house rules, code style, or team tone.")
                    .font(.system(size: TypeScale.caption))
                    .foregroundStyle(Color.textQuaternary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                }

                TextEditor(text: $codexInstructions)
                  .font(.system(size: TypeScale.body))
                  .foregroundStyle(Color.textPrimary)
                  .scrollContentBackground(.hidden)
                  .frame(minHeight: 92, maxHeight: 120)
                  .padding(.horizontal, Spacing.sm)
                  .padding(.vertical, Spacing.xs)
              }
            } else {
              RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .fill(Color.backgroundSecondary)
                .frame(minHeight: 72)
                .overlay(alignment: .leading) {
                  Text("This model does not currently expose durable session instructions through OrbitDock.")
                    .font(.system(size: TypeScale.caption))
                    .foregroundStyle(Color.textQuaternary)
                    .padding(.horizontal, Spacing.md)
                }
                .overlay(
                  RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .stroke(Color.surfaceBorder, lineWidth: 1)
                )
            }

            Text(
              "Use this for durable session behavior. For one-off guidance later, steer the active turn from the composer."
            )
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
          }
        }
        .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.md)
  }

  private var codexAdvancedSummary: String {
    var summary: [String] = []

    if codexPersonality != .automatic {
      summary.append(codexPersonality.displayName)
    }
    if codexServiceTier != .automatic {
      summary.append(codexServiceTier.displayName)
    }
    if codexMultiAgentEnabled {
      summary.append("Workers on")
    }
    if !codexInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      summary.append("Instructions ready")
    }

    if summary.isEmpty {
      return "Personality, service tier, and session instructions"
    }

    return summary.joined(separator: " • ")
  }

  private func codexAdvancedPickerCard(
    title: String,
    icon: String,
    tint: Color,
    @ViewBuilder control: () -> some View,
    @ViewBuilder description: () -> some View
  ) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(spacing: Spacing.sm) {
        Image(systemName: icon)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(tint)
        Text(title)
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textSecondary)
      }

      control()
        .frame(maxWidth: .infinity, alignment: .leading)

      description()
        .font(.system(size: TypeScale.micro))
        .foregroundStyle(Color.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(Spacing.md)
    .background(Color.backgroundSecondary, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .stroke(Color.surfaceBorder, lineWidth: 1)
    )
  }
}
