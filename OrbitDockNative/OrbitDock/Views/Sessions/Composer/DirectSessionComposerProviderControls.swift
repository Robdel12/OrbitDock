import SwiftUI

extension DirectSessionComposer {
  var modelEffortControlButton: some View {
    Button {
      showModelEffortPopover.toggle()
      Platform.services.playHaptic(.selection)
    } label: {
      ghostActionLabel(icon: "slider.horizontal.3", isActive: hasOverrides)
    }
    .buttonStyle(.plain)
    .help("Model and reasoning effort")
    .platformPopover(isPresented: $composerState.showModelEffortPopover) {
      #if os(iOS)
        NavigationStack {
          ModelEffortPopover(
            selectedModel: $composerState.selectedModel,
            selectedEffort: $composerState.selectedEffort,
            models: codexModelOptions,
            currentModel: effectiveCodexModel,
            allowsModelSelection: codexAllowsModelSelection,
            noticeMessage: codexScopedModelNoticeMessage,
            noticeIsLoading: scopedCodexModelsLoading
          )
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button("Done") { showModelEffortPopover = false }
            }
          }
        }
      #else
        ModelEffortPopover(
          selectedModel: $composerState.selectedModel,
          selectedEffort: $composerState.selectedEffort,
          models: codexModelOptions,
          currentModel: effectiveCodexModel,
          allowsModelSelection: codexAllowsModelSelection,
          noticeMessage: codexScopedModelNoticeMessage,
          noticeIsLoading: scopedCodexModelsLoading
        )
      #endif
    }
  }

  var claudeModelControlButton: some View {
    Button {
      showClaudeModelPopover.toggle()
      Platform.services.playHaptic(.selection)
    } label: {
      ghostActionLabel(icon: "slider.horizontal.3", isActive: hasOverrides, tint: .providerClaude)
    }
    .buttonStyle(.plain)
    .help("Claude model override")
    .platformPopover(isPresented: $composerState.showClaudeModelPopover) {
      #if os(iOS)
        NavigationStack {
          ComposerClaudeModelPopover(
            selectedModel: $composerState.selectedClaudeModel,
            models: claudeModelOptions
          )
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button("Done") { showClaudeModelPopover = false }
            }
          }
        }
      #else
        ComposerClaudeModelPopover(
          selectedModel: $composerState.selectedClaudeModel,
          models: claudeModelOptions
        )
      #endif
    }
  }

  var codexSettingsControlButton: some View {
    Button {
      showCodexSettingsSheet = true
      Platform.services.playHaptic(.selection)
    } label: {
      ghostActionLabel(
        icon: "slider.horizontal.below.rectangle",
        isActive: hasCodexControlOverrides,
        tint: .providerCodex
      )
    }
    .buttonStyle(.plain)
    .help("Codex config and session overrides")
  }

  @ViewBuilder
  var providerModelControlButton: some View {
    if obs.isDirectCodex {
      HStack(spacing: Spacing.xs) {
        modelEffortControlButton
        codexSettingsControlButton
      }
    } else if obs.isDirectClaude {
      claudeModelControlButton
    }
  }
}

struct CodexSessionSettingsSheet: View {
  let projectPath: String?
  let modelOption: ServerCodexModelOption?
  let approvalPolicy: String?
  let approvalPolicyDetails: ServerCodexApprovalPolicy?
  let sandboxMode: String?
  let configMode: ServerCodexConfigMode
  let configProfile: String?
  let modelProvider: String?
  let collaborationMode: CodexCollaborationMode
  let multiAgentEnabled: Bool
  let personality: CodexPersonalityPreset
  let serviceTier: CodexServiceTierPreset
  let developerInstructions: String?
  let fetchCatalog: @MainActor @Sendable (String) async throws -> SessionsClient.CodexConfigCatalogResponse
  let onApply: @MainActor @Sendable (
    ServerCodexConfigMode,
    String?,
    String?,
    ServerCodexApprovalPolicy,
    CodexCollaborationMode,
    Bool,
    CodexPersonalityPreset,
    CodexServiceTierPreset,
    String?
  ) async throws -> Void
  let onReset: @MainActor @Sendable () async throws -> Void
  let onInspect: @MainActor @Sendable () -> Void
  let onManageConfig: @MainActor @Sendable () -> Void
  let onDone: @MainActor @Sendable () -> Void

  @State private var draftConfigMode: ServerCodexConfigMode
  @State private var draftConfigProfile: String
  @State private var draftModelProvider: String
  @State private var draftApprovalPolicy: CodexApprovalPolicyDraft
  @State private var draftCollaborationMode: CodexCollaborationMode
  @State private var draftMultiAgentEnabled: Bool
  @State private var draftPersonality: CodexPersonalityPreset
  @State private var draftServiceTier: CodexServiceTierPreset
  @State private var draftInstructions: String
  @State private var catalog: SessionsClient.CodexConfigCatalogResponse?
  @State private var catalogError: String?
  @State private var actionError: String?
  @State private var catalogLoading = false
  @State private var isApplying = false
  @State private var catalogRequestID = 0

  private var profileOptions: [SessionsClient.CodexConfigProfileSummary] {
    catalog?.profiles ?? []
  }

  private var providerOptions: [SessionsClient.CodexProviderSummary] {
    catalog?.providers ?? []
  }

  private var availableCollaborationModes: [CodexCollaborationMode] {
    CodexCollaborationMode.supportedCases(from: modelOption)
  }

  private var availableServiceTiers: [CodexServiceTierPreset] {
    CodexServiceTierPreset.supportedCases(from: modelOption)
  }

  private var supportsMultiAgent: Bool {
    modelOption?.supportsMultiAgent ?? true
  }

  private var multiAgentIsExperimental: Bool {
    modelOption?.multiAgentIsExperimental ?? true
  }

  private var supportsPersonality: Bool {
    modelOption?.supportsPersonality ?? true
  }

  private var supportsDeveloperInstructions: Bool {
    modelOption?.supportsDeveloperInstructions ?? true
  }

  private var selectedProfileSummary: SessionsClient.CodexConfigProfileSummary? {
    profileOptions.first {
      $0.name == draftConfigProfile.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  private var selectedProviderSummary: SessionsClient.CodexProviderSummary? {
    providerOptions.first {
      $0.id == draftModelProvider.trimmingCharacters(in: .whitespacesAndNewlines)
    }
  }

  private var configModeTitle: String {
    switch draftConfigMode {
      case .inherit:
        "From Codex config"
      case .profile:
        "Saved profile"
      case .custom:
        "Custom session config"
    }
  }

  private var configurationEditingNotice: String {
    "Provider and profile selection are set when the Codex session starts. You can inspect them here, but changing them still requires a fresh session."
  }

  init(
    projectPath: String?,
    modelOption: ServerCodexModelOption?,
    approvalPolicy: String?,
    approvalPolicyDetails: ServerCodexApprovalPolicy?,
    sandboxMode: String?,
    configMode: ServerCodexConfigMode,
    configProfile: String?,
    modelProvider: String?,
    collaborationMode: CodexCollaborationMode,
    multiAgentEnabled: Bool,
    personality: CodexPersonalityPreset,
    serviceTier: CodexServiceTierPreset,
    developerInstructions: String?,
    fetchCatalog: @escaping @MainActor @Sendable (String) async throws -> SessionsClient.CodexConfigCatalogResponse,
    onApply: @escaping @MainActor @Sendable (
      ServerCodexConfigMode,
      String?,
      String?,
      ServerCodexApprovalPolicy,
      CodexCollaborationMode,
      Bool,
      CodexPersonalityPreset,
      CodexServiceTierPreset,
      String?
    ) async throws -> Void,
    onReset: @escaping @MainActor @Sendable () async throws -> Void,
    onInspect: @escaping @MainActor @Sendable () -> Void,
    onManageConfig: @escaping @MainActor @Sendable () -> Void,
    onDone: @escaping @MainActor @Sendable () -> Void
  ) {
    self.projectPath = projectPath
    self.modelOption = modelOption
    self.approvalPolicy = approvalPolicy
    self.approvalPolicyDetails = approvalPolicyDetails
    self.sandboxMode = sandboxMode
    self.configMode = configMode
    self.configProfile = configProfile
    self.modelProvider = modelProvider
    self.collaborationMode = collaborationMode
    self.multiAgentEnabled = multiAgentEnabled
    self.personality = personality
    self.serviceTier = serviceTier
    self.developerInstructions = developerInstructions
    self.fetchCatalog = fetchCatalog
    self.onApply = onApply
    self.onReset = onReset
    self.onInspect = onInspect
    self.onManageConfig = onManageConfig
    self.onDone = onDone
    _draftConfigMode = State(initialValue: configMode)
    _draftConfigProfile = State(initialValue: configProfile ?? "")
    _draftModelProvider = State(initialValue: modelProvider ?? "")
    _draftApprovalPolicy = State(
      initialValue: CodexApprovalPolicyDraft(
        policy: approvalPolicyDetails,
        fallbackPolicy: approvalPolicy
      )
    )
    _draftCollaborationMode = State(initialValue: collaborationMode)
    _draftMultiAgentEnabled = State(initialValue: multiAgentEnabled)
    _draftPersonality = State(initialValue: personality)
    _draftServiceTier = State(initialValue: serviceTier)
    _draftInstructions = State(initialValue: developerInstructions ?? "")
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: Spacing.lg) {
          settingsCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
              HStack(alignment: .top, spacing: Spacing.md) {
                if let projectPath, !projectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                  VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text("Workspace")
                      .font(.system(size: TypeScale.micro, weight: .semibold))
                      .foregroundStyle(Color.textQuaternary)
                    Text(projectPath)
                      .font(.system(size: TypeScale.caption, design: .monospaced))
                      .foregroundStyle(Color.textTertiary)
                      .lineLimit(2)
                      .truncationMode(.middle)
                      .textSelection(.enabled)
                  }
                }

                Spacer(minLength: Spacing.md)

                settingsStatusPill(title: configModeTitle, tint: .providerCodex)
              }

              Text(
                "This session started from the Codex config for the project folder. Live controls here can tune collaboration and behavior without restarting the session."
              )
              .font(.system(size: TypeScale.body))
              .foregroundStyle(Color.textSecondary)
              .fixedSize(horizontal: false, vertical: true)

              VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Provider and profile selection are shown for context.")
                Text("Start a new Codex session if you want to switch them.")
              }
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.textTertiary)
              .fixedSize(horizontal: false, vertical: true)

              HStack(spacing: Spacing.md) {
                Button("Manage Profiles & Providers") {
                  onManageConfig()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Inspect Codex Config") {
                  onInspect()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()
              }
            }
          }

          settingsCard {
            VStack(alignment: .leading, spacing: Spacing.md) {
              composerSectionLabel("Configuration")

              Picker("Configuration", selection: $draftConfigMode) {
                Text("From Codex config").tag(ServerCodexConfigMode.inherit)
                Text("Saved profile").tag(ServerCodexConfigMode.profile)
                Text("Custom session config").tag(ServerCodexConfigMode.custom)
              }
              .pickerStyle(.segmented)
              .disabled(true)

              settingsHintCard(
                title: "Launch-time setting",
                detail: configurationEditingNotice,
                buttonTitle: "Manage Profiles & Providers",
                action: onManageConfig
              )

              if draftConfigMode == .profile {
                Picker("Saved profile", selection: $draftConfigProfile) {
                  Text(profileOptions.isEmpty ? "No profiles found" : "Select a profile").tag("")
                  ForEach(profileOptions) { profile in
                    Text(profile.name).tag(profile.name)
                  }
                }
                .pickerStyle(.menu)
                .disabled(true)

                settingsHintCard(
                  title: selectedProfileSummary
                    .map { "Using profile: \($0.name)" } ?? "Saved profiles live in Codex config",
                  detail: selectedProfileSummary.map {
                    [
                      $0.modelProvider.map { "Provider: \($0)" },
                      $0.model.map { "Model: \($0)" },
                    ]
                    .compactMap { $0 }
                    .joined(separator: " • ")
                  } ??
                    "Choose one of your saved Codex profiles here, or use Manage Profiles & Providers to create or edit them.",
                  buttonTitle: "Manage Profiles",
                  action: onManageConfig
                )
              } else if draftConfigMode == .custom {
                Picker("Provider", selection: $draftModelProvider) {
                  Text(providerOptions.isEmpty ? "No providers found" : "Select a provider").tag("")
                  ForEach(providerOptions) { provider in
                    Text(provider.displayName ?? provider.id).tag(provider.id)
                  }
                }
                .pickerStyle(.menu)
                .disabled(true)

                settingsHintCard(
                  title: selectedProviderSummary?.displayName ?? selectedProviderSummary?
                    .id ?? "Custom providers live in Codex config",
                  detail: selectedProviderSummary.map {
                    [
                      $0.baseURL.map { "Base URL: \($0)" },
                      $0.envKey.map { "Key: \($0)" },
                      $0.wireAPI.map { "API: \($0)" },
                    ]
                    .compactMap { $0 }
                    .joined(separator: " • ")
                  } ??
                    "Pick a provider here for this session, or use Manage Profiles & Providers to add and edit custom providers.",
                  buttonTitle: "Manage Providers",
                  action: onManageConfig
                )
              }

              if let catalogError, !catalogError.isEmpty {
                errorCard(title: "Couldn't load Codex config options", message: catalogError)
              } else if catalogLoading {
                HStack(spacing: Spacing.sm) {
                  ProgressView()
                    .controlSize(.small)
                  Text("Loading Codex profiles and providers…")
                    .font(.system(size: TypeScale.caption))
                    .foregroundStyle(Color.textTertiary)
                }
              }
            }
          }

          settingsCard {
            VStack(alignment: .leading, spacing: Spacing.lg) {
              composerSectionLabel("Approval")

              settingsRow(
                title: "Review Style",
                icon: draftApprovalPolicy.style == .granular ? "dial.low" : "slider.horizontal.3",
                tint: .providerCodex,
                description: draftApprovalPolicy.policy.summary
              ) {
                Picker("Review Style", selection: $draftApprovalPolicy.style) {
                  ForEach(CodexApprovalPolicyEditorStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                  }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
              }

              if draftApprovalPolicy.style == .preset {
                settingsRow(
                  title: "Approval Preset",
                  icon: "shield.lefthalf.filled",
                  tint: .providerCodex,
                  description: draftApprovalPolicy.presetMode.summary
                ) {
                  Picker("Approval Preset", selection: $draftApprovalPolicy.presetMode) {
                    ForEach(ServerCodexApprovalMode.allCases, id: \.self) { mode in
                      Text(mode.displayName).tag(mode)
                    }
                  }
                  .pickerStyle(.menu)
                  .frame(minWidth: 180, alignment: .trailing)
                }
              } else {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                  ForEach(CodexApprovalToggleField.allCases) { field in
                    Toggle(isOn: granularToggleBinding(for: field)) {
                      VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(field.title)
                          .font(.system(size: TypeScale.caption, weight: .semibold))
                          .foregroundStyle(Color.textPrimary)
                        Text(field.detail)
                          .font(.system(size: TypeScale.micro))
                          .foregroundStyle(Color.textTertiary)
                          .fixedSize(horizontal: false, vertical: true)
                      }
                    }
                    .toggleStyle(.switch)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                    .background(
                      Color.backgroundSecondary,
                      in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    )
                    .overlay(
                      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                        .stroke(Color.surfaceBorder, lineWidth: 1)
                    )
                  }
                }
              }

              settingsHintCard(
                title: "Current sandbox: \(sandboxMode ?? "Inherited")",
                detail: "Sandboxing still controls where Codex runs. This section only adjusts how approval review behaves inside that environment.",
                buttonTitle: "Inspect Codex Config",
                action: onInspect
              )

              settingsRow(
                title: "Collaboration",
                icon: draftCollaborationMode.icon,
                tint: draftCollaborationMode.color,
                description: draftCollaborationMode.description
              ) {
                Picker("Collaboration", selection: $draftCollaborationMode) {
                  ForEach(availableCollaborationModes) { mode in
                    Text(mode.displayName).tag(mode)
                  }
                }
                .pickerStyle(.menu)
                .frame(minWidth: 180, alignment: .trailing)
              }

              settingsRow(
                title: "Workers",
                icon: draftMultiAgentEnabled ? "person.3.fill" : "person.3",
                tint: draftMultiAgentEnabled ? .providerCodex : .textTertiary,
                badge: multiAgentIsExperimental ? "EXPERIMENTAL" : nil,
                description: supportsMultiAgent
                  ? (
                    draftMultiAgentEnabled
                      ? "Let Codex coordinate helper workers in this session."
                      : "Keep this session single-threaded. Collaboration mode still applies to the main agent."
                  )
                  : "This model does not currently advertise worker spawning support to OrbitDock."
              ) {
                Toggle("", isOn: $draftMultiAgentEnabled)
                  .labelsHidden()
                  .toggleStyle(.switch)
                  .disabled(!supportsMultiAgent)
              }

              if let actionError, !actionError.isEmpty {
                errorCard(title: "Couldn't save Codex session overrides", message: actionError)
              }

              HStack(alignment: .top, spacing: Spacing.md) {
                insetCard {
                  VStack(alignment: .leading, spacing: Spacing.sm) {
                    composerFieldLabel("Personality", icon: draftPersonality.icon, tint: draftPersonality.color)
                    if supportsPersonality {
                      Picker("Personality", selection: $draftPersonality) {
                        ForEach(CodexPersonalityPreset.allCases) { preset in
                          Text(preset.displayName).tag(preset)
                        }
                      }
                      .pickerStyle(.menu)
                    } else {
                      Text("Unavailable")
                        .font(.system(size: TypeScale.body, weight: .semibold))
                        .foregroundStyle(Color.textQuaternary)
                    }

                    Text(
                      supportsPersonality
                        ? draftPersonality.description
                        : "This model does not currently expose personality overrides through OrbitDock."
                    )
                    .font(.system(size: TypeScale.micro))
                    .foregroundStyle(Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                  }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                insetCard {
                  VStack(alignment: .leading, spacing: Spacing.sm) {
                    composerFieldLabel("Service Tier", icon: draftServiceTier.icon, tint: draftServiceTier.color)
                    Picker("Service Tier", selection: $draftServiceTier) {
                      ForEach(availableServiceTiers) { preset in
                        Text(preset.displayName).tag(preset)
                      }
                    }
                    .pickerStyle(.menu)

                    Text(draftServiceTier.description)
                      .font(.system(size: TypeScale.micro))
                      .foregroundStyle(Color.textTertiary)
                      .fixedSize(horizontal: false, vertical: true)
                  }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
              }
            }
          }

          settingsCard {
            VStack(alignment: .leading, spacing: Spacing.sm) {
              composerFieldLabel("Durable Instructions", icon: "text.append", tint: .accent)
              if supportsDeveloperInstructions {
                ZStack(alignment: .topLeading) {
                  RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(Color.backgroundPrimary)
                    .overlay(
                      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                        .stroke(Color.surfaceBorder, lineWidth: 1)
                    )

                  if draftInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Persistent guidance for the rest of the session.")
                      .font(.system(size: TypeScale.caption))
                      .foregroundStyle(Color.textQuaternary)
                      .padding(.horizontal, Spacing.md)
                      .padding(.vertical, Spacing.sm)
                  }

                  TextEditor(text: $draftInstructions)
                    .font(.system(size: TypeScale.body))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 140, maxHeight: 220)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, Spacing.xs)
                }
              } else {
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                  .fill(Color.backgroundPrimary)
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
                supportsDeveloperInstructions
                  ? "Use Steer when you want a one-turn nudge instead of a durable session rule."
                  : "Steer the active turn if you still want one-off guidance for this model."
              )
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.textTertiary)
              .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        .frame(maxWidth: 720, alignment: .leading)
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.xl)
        .padding(.bottom, Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .top)
      }

      Divider()
        .overlay(Color.surfaceBorder.opacity(OpacityTier.subtle))

      HStack {
        Button("Reset Live Overrides") {
          Task {
            await MainActor.run {
              isApplying = true
              actionError = nil
            }
            do {
              try await onReset()
              await MainActor.run {
                isApplying = false
                onDone()
              }
            } catch {
              await MainActor.run {
                isApplying = false
                actionError = "Couldn't reset Codex config overrides just now."
              }
            }
          }
        }
        .buttonStyle(.plain)
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(Color.accent)
        .disabled(isApplying)

        Spacer()

        Button {
          Task {
            await MainActor.run {
              isApplying = true
              actionError = nil
            }
            do {
              try await onApply(
                draftConfigMode,
                draftConfigProfile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : draftConfigProfile,
                draftModelProvider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : draftModelProvider,
                draftApprovalPolicy.policy,
                draftCollaborationMode,
                draftMultiAgentEnabled,
                draftPersonality,
                draftServiceTier,
                draftInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : draftInstructions
              )
              await MainActor.run {
                isApplying = false
                onDone()
              }
            } catch {
              await MainActor.run {
                isApplying = false
                actionError = "Couldn't update Codex session settings just now."
              }
            }
          }
        } label: {
          if isApplying {
            ProgressView()
              .controlSize(.small)
          } else {
            Text("Apply")
          }
        }
        .buttonStyle(GhostButtonStyle(color: .accent, size: .compact))
        .disabled(isApplying)
      }
      .padding(.horizontal, Spacing.xl)
      .padding(.vertical, Spacing.lg)
      .background(Color.backgroundSecondary)
    }
    .background(Color.backgroundSecondary)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .task(id: projectPath ?? "") {
      await refreshCatalog()
    }
  }

  private func composerFieldLabel(_ title: String, icon: String, tint: Color) -> some View {
    HStack(spacing: Spacing.xs) {
      Image(systemName: icon)
        .font(.system(size: TypeScale.mini, weight: .semibold))
        .foregroundStyle(tint)
      Text(title)
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(Color.textSecondary)
    }
  }

  private func granularToggleBinding(for field: CodexApprovalToggleField) -> Binding<Bool> {
    Binding(
      get: { draftApprovalPolicy.isEnabled(field) },
      set: { draftApprovalPolicy.setEnabled($0, for: field) }
    )
  }

  private func composerSectionLabel(_ title: String) -> some View {
    Text(title)
      .font(.system(size: TypeScale.caption, weight: .semibold))
      .foregroundStyle(Color.textSecondary)
  }

  private func settingsCard(@ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(Spacing.lg)
    .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .stroke(Color.surfaceBorder, lineWidth: 1)
    )
  }

  private func insetCard(@ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(Spacing.md)
    .background(Color.backgroundSecondary, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .stroke(Color.surfaceBorder, lineWidth: 1)
    )
  }

  private func settingsRow(
    title: String,
    icon: String,
    tint: Color,
    badge: String? = nil,
    description: String,
    @ViewBuilder control: () -> some View
  ) -> some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack(alignment: .center, spacing: Spacing.md) {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          HStack(spacing: Spacing.xs) {
            composerFieldLabel(title, icon: icon, tint: tint)
            if let badge {
              Text(badge)
                .font(.system(size: 7, weight: .bold, design: .rounded))
                .foregroundStyle(Color.feedbackCaution)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Color.feedbackCaution.opacity(OpacityTier.light), in: Capsule())
            }
          }
          Text(description)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: Spacing.lg)

        control()
      }
    }
  }

  private func errorCard(title: String, message: String) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(title)
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(Color.feedbackNegative)
      Text(message)
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(Spacing.sm)
    .background(Color.feedbackNegative.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .stroke(Color.feedbackNegative.opacity(0.25), lineWidth: 1)
    )
  }

  private func settingsHintCard(
    title: String,
    detail: String,
    buttonTitle: String,
    action: @escaping @MainActor @Sendable () -> Void
  ) -> some View {
    HStack(alignment: .top, spacing: Spacing.md) {
      VStack(alignment: .leading, spacing: Spacing.xxs) {
        Text(title)
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textSecondary)
        Text(detail)
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textTertiary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer()

      Button(buttonTitle) {
        action()
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
    .padding(Spacing.sm)
    .background(Color.backgroundSecondary, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .stroke(Color.surfaceBorder, lineWidth: 1)
    )
  }

  private func settingsStatusPill(title: String, tint: Color) -> some View {
    Text(title)
      .font(.system(size: TypeScale.micro, weight: .semibold))
      .foregroundStyle(tint)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, 6)
      .background(tint.opacity(0.12), in: Capsule())
      .overlay(
        Capsule()
          .stroke(tint.opacity(0.25), lineWidth: 1)
      )
  }

  @MainActor
  private func refreshCatalog() async {
    guard let projectPath, !projectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    catalogRequestID += 1
    let requestID = catalogRequestID
    catalogLoading = true
    catalogError = nil
    do {
      let response = try await fetchCatalog(projectPath)
      guard requestID == catalogRequestID else { return }
      catalog = response
    } catch {
      guard requestID == catalogRequestID else { return }
      catalog = nil
      catalogError = codexCatalogErrorMessage(for: error)
    }
    catalogLoading = false
  }

  private func codexCatalogErrorMessage(for error: Error) -> String {
    if let requestError = error as? ServerRequestError {
      return requestError.localizedDescription
    }
    if let decodingError = error as? DecodingError {
      switch decodingError {
        case let .keyNotFound(key, _):
          return "OrbitDock couldn't decode the Codex config catalog because '\(key.stringValue)' was missing in the server response."
        case let .typeMismatch(_, context):
          return "OrbitDock couldn't decode the Codex config catalog at \(codingPathDescription(context.codingPath))."
        case let .valueNotFound(_, context):
          return "OrbitDock expected config data at \(codingPathDescription(context.codingPath)), but it wasn't present."
        case let .dataCorrupted(context):
          return "OrbitDock received malformed Codex config data at \(codingPathDescription(context.codingPath))."
        @unknown default:
          return error.localizedDescription
      }
    }
    return error.localizedDescription
  }

  private func codingPathDescription(_ path: [CodingKey]) -> String {
    guard !path.isEmpty else { return "the root response" }
    return path.map(\.stringValue).joined(separator: ".")
  }
}
