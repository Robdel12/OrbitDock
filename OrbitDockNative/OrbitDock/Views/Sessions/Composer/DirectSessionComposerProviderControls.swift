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
            models: codexModelOptions
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
          models: codexModelOptions
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
      showCodexSettingsPopover.toggle()
      Platform.services.playHaptic(.selection)
    } label: {
      ghostActionLabel(
        icon: "slider.horizontal.below.rectangle",
        isActive: hasCodexControlOverrides,
        tint: .providerCodex
      )
    }
    .buttonStyle(.plain)
    .help("Codex collaboration and session settings")
    .platformPopover(isPresented: $composerState.showCodexSettingsPopover) {
      #if os(iOS)
        NavigationStack {
          CodexSessionSettingsPopover(
            collaborationMode: currentCodexCollaborationMode,
            multiAgentEnabled: currentCodexMultiAgentEnabled,
            personality: currentCodexPersonality,
            serviceTier: currentCodexServiceTier,
            developerInstructions: obs.developerInstructions,
            onApply: applyCodexSessionSettings
          )
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button("Done") { showCodexSettingsPopover = false }
            }
          }
        }
      #else
        CodexSessionSettingsPopover(
          collaborationMode: currentCodexCollaborationMode,
          multiAgentEnabled: currentCodexMultiAgentEnabled,
          personality: currentCodexPersonality,
          serviceTier: currentCodexServiceTier,
          developerInstructions: obs.developerInstructions,
          onApply: applyCodexSessionSettings
        )
      #endif
    }
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

private struct CodexSessionSettingsPopover: View {
  let collaborationMode: CodexCollaborationMode
  let multiAgentEnabled: Bool
  let personality: CodexPersonalityPreset
  let serviceTier: CodexServiceTierPreset
  let developerInstructions: String?
  let onApply: @MainActor @Sendable (
    CodexCollaborationMode,
    Bool,
    CodexPersonalityPreset,
    CodexServiceTierPreset,
    String?
  ) async -> Void

  @State private var draftCollaborationMode: CodexCollaborationMode
  @State private var draftMultiAgentEnabled: Bool
  @State private var draftPersonality: CodexPersonalityPreset
  @State private var draftServiceTier: CodexServiceTierPreset
  @State private var draftInstructions: String
  @State private var isApplying = false

  init(
    collaborationMode: CodexCollaborationMode,
    multiAgentEnabled: Bool,
    personality: CodexPersonalityPreset,
    serviceTier: CodexServiceTierPreset,
    developerInstructions: String?,
    onApply: @escaping @MainActor @Sendable (
      CodexCollaborationMode,
      Bool,
      CodexPersonalityPreset,
      CodexServiceTierPreset,
      String?
    ) async -> Void
  ) {
    self.collaborationMode = collaborationMode
    self.multiAgentEnabled = multiAgentEnabled
    self.personality = personality
    self.serviceTier = serviceTier
    self.developerInstructions = developerInstructions
    self.onApply = onApply
    _draftCollaborationMode = State(initialValue: collaborationMode)
    _draftMultiAgentEnabled = State(initialValue: multiAgentEnabled)
    _draftPersonality = State(initialValue: personality)
    _draftServiceTier = State(initialValue: serviceTier)
    _draftInstructions = State(initialValue: developerInstructions ?? "")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      Text("Codex Session Settings")
        .font(.system(size: TypeScale.subhead, weight: .semibold))
        .foregroundStyle(Color.textPrimary)

      VStack(alignment: .leading, spacing: Spacing.sm) {
        composerFieldLabel("Collaboration", icon: draftCollaborationMode.icon, tint: draftCollaborationMode.color)
        Picker("Collaboration", selection: $draftCollaborationMode) {
          ForEach(CodexCollaborationMode.allCases) { mode in
            Text(mode.displayName).tag(mode)
          }
        }
        .pickerStyle(.menu)

        Text(draftCollaborationMode.description)
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textTertiary)
          .fixedSize(horizontal: false, vertical: true)
      }

      VStack(alignment: .leading, spacing: Spacing.sm) {
        HStack(alignment: .top, spacing: Spacing.md) {
          composerFieldLabel(
            "Workers",
            icon: draftMultiAgentEnabled ? "person.3.fill" : "person.3",
            tint: draftMultiAgentEnabled ? .providerCodex : .textTertiary
          )

          Spacer()

          Toggle("", isOn: $draftMultiAgentEnabled)
            .labelsHidden()
            .toggleStyle(.switch)
        }

        Text(
          draftMultiAgentEnabled
            ? "Let Codex coordinate helper workers in this session."
            : "Keep this session single-threaded. Collaboration mode still applies to the main agent."
        )
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
      }

      HStack(alignment: .top, spacing: Spacing.md) {
        VStack(alignment: .leading, spacing: Spacing.sm) {
          composerFieldLabel("Personality", icon: draftPersonality.icon, tint: draftPersonality.color)
          Picker("Personality", selection: $draftPersonality) {
            ForEach(CodexPersonalityPreset.allCases) { preset in
              Text(preset.displayName).tag(preset)
            }
          }
          .pickerStyle(.menu)

          Text(draftPersonality.description)
            .font(.system(size: TypeScale.micro))
            .foregroundStyle(Color.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        VStack(alignment: .leading, spacing: Spacing.sm) {
          composerFieldLabel("Service Tier", icon: draftServiceTier.icon, tint: draftServiceTier.color)
          Picker("Service Tier", selection: $draftServiceTier) {
            ForEach(CodexServiceTierPreset.allCases) { preset in
              Text(preset.displayName).tag(preset)
            }
          }
          .pickerStyle(.menu)

          Text(draftServiceTier.description)
            .font(.system(size: TypeScale.micro))
            .foregroundStyle(Color.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      VStack(alignment: .leading, spacing: Spacing.sm) {
        composerFieldLabel("Durable Instructions", icon: "text.append", tint: .accent)
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
            .frame(minHeight: 92, maxHeight: 132)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
        }

        Text("Use Steer when you want a one-turn nudge instead of a durable session rule.")
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textTertiary)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack {
        Spacer()

        Button {
          Task {
            await MainActor.run { isApplying = true }
            await onApply(
              draftCollaborationMode,
              draftMultiAgentEnabled,
              draftPersonality,
              draftServiceTier,
              draftInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : draftInstructions
            )
            await MainActor.run { isApplying = false }
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
    }
    .padding(Spacing.lg)
    .ifMacOS { $0.frame(width: 340) }
    .background(Color.backgroundSecondary)
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
}
