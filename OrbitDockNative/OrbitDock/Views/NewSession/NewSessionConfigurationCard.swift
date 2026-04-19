import SwiftUI

struct NewSessionConfigurationCard: View {
  enum Style {
    case card
    case embedded
  }

  @State var showCodexAdvancedSettings = false

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
  let codexCatalog: SessionsClient.CodexConfigCatalogResponse?
  let codexCatalogLoading: Bool
  let codexCatalogError: String?
  let codexScopedModelProvider: String?
  let codexScopedModelsLoading: Bool
  let codexScopedModelError: String?
  let onInspectCodexConfig: (() -> Void)?
  let onManageCodexConfig: (() -> Void)?

  var currentCodexModelOption: ServerCodexModelOption? {
    let normalizedModel = codexModel.trimmingCharacters(in: .whitespacesAndNewlines)
    if !normalizedModel.isEmpty {
      return codexModels.first(where: { $0.model == normalizedModel })
    }
    return codexModels.first(where: \.isDefault) ?? codexModels.first
  }

  var availableCodexCollaborationModes: [CodexCollaborationMode] {
    CodexCollaborationMode.supportedCases(from: currentCodexModelOption)
  }

  var availableCodexServiceTiers: [CodexServiceTierPreset] {
    CodexServiceTierPreset.supportedCases(from: currentCodexModelOption)
  }

  var codexSupportsMultiAgent: Bool {
    currentCodexModelOption?.supportsMultiAgent ?? true
  }

  var codexMultiAgentIsExperimental: Bool {
    currentCodexModelOption?.multiAgentIsExperimental ?? true
  }

  var codexSupportsPersonality: Bool {
    currentCodexModelOption?.supportsPersonality ?? true
  }

  var codexSupportsDeveloperInstructions: Bool {
    currentCodexModelOption?.supportsDeveloperInstructions ?? true
  }

  var profileOptions: [SessionsClient.CodexConfigProfileSummary] {
    codexCatalog?.profiles.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } ?? []
  }

  var providerOptions: [SessionsClient.CodexProviderSummary] {
    codexCatalog?.providers.sorted {
      ($0.displayName ?? $0.id).localizedCaseInsensitiveCompare($1.displayName ?? $1.id) == .orderedAscending
    } ?? []
  }

  var selectedProfileSummary: SessionsClient.CodexConfigProfileSummary? {
    profileOptions.first(where: { $0.name == codexConfigProfile })
  }

  var selectedProviderSummary: SessionsClient.CodexProviderSummary? {
    providerOptions.first(where: { $0.id == codexModelProvider })
  }

  var codexModelDisplayName: String {
    if let option = currentCodexModelOption {
      return option.displayName
    }
    let normalizedModel = codexModel.trimmingCharacters(in: .whitespacesAndNewlines)
    return normalizedModel.isEmpty ? "Choose model" : normalizedModel
  }

  var usesCustomCodexConfig: Bool {
    codexConfigMode == .custom
  }

  var codexScopedModelNotice: String? {
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

  var codexResolvedProfileLabel: String {
    switch codexConfigMode {
      case .inherit:
        codexCatalog?.effectiveSettings?.configProfile ?? "Folder default"
      case .profile:
        selectedProfileSummary?.name ?? "Saved profile"
      case .custom:
        "Custom session"
    }
  }

  var codexResolvedProviderLabel: String {
    switch codexConfigMode {
      case .inherit:
        codexCatalog?.effectiveSettings?.modelProvider ?? "Resolved by Codex"
      case .profile:
        selectedProfileSummary?.modelProvider ?? "From selected profile"
      case .custom:
        selectedProviderSummary?.displayName ?? selectedProviderSummary?.id ?? "Choose provider"
    }
  }

  var codexResolvedModelLabel: String {
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
}
