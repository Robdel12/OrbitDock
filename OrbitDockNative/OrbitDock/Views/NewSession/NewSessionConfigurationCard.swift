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
  @Binding var codexUseOrbitDockOverrides: Bool
  @Binding var selectedAutonomy: AutonomyLevel
  @Binding var codexCollaborationMode: CodexCollaborationMode
  @Binding var codexMultiAgentEnabled: Bool
  @Binding var codexPersonality: CodexPersonalityPreset
  @Binding var codexServiceTier: CodexServiceTierPreset
  @Binding var codexInstructions: String
  let onInspectCodexConfig: (() -> Void)?

  private var currentCodexModelOption: ServerCodexModelOption? {
    codexModels.first(where: { $0.model == codexModel }) ?? codexModels.first(where: \.isDefault) ?? codexModels.first
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

  private var inheritsFromCodexConfig: Bool {
    !codexUseOrbitDockOverrides
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      modelRow

      Divider()
        .padding(.horizontal, Spacing.lg)

      switch provider {
        case .claude:
          claudePermissionRow

          claudeBypassRow

          Divider()
            .padding(.horizontal, Spacing.lg)

          claudeEffortRow

        case .codex:
          codexInheritanceRow

          if !inheritsFromCodexConfig {
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
          }
      }
    }
    .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .stroke(Color.surfaceBorder, lineWidth: 1)
    )
  }

  private var codexInheritanceRow: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      HStack {
        HStack(spacing: Spacing.sm) {
          Image(systemName: "doc.text.magnifyingglass")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.providerCodex)
          Text("Codex Config")
            .font(.system(size: TypeScale.body, weight: .medium))
            .foregroundStyle(Color.textSecondary)
        }

        Spacer()
      }

      Text(
        "OrbitDock resolves the Codex config that applies to the selected folder, including your user config and any project-level `.codex` config."
      )
      .font(.system(size: TypeScale.caption))
      .foregroundStyle(Color.textTertiary)
      .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: Spacing.md) {
        Toggle("Customize for this session", isOn: $codexUseOrbitDockOverrides)
          .toggleStyle(.switch)
          .tint(Color.providerCodex)

        Spacer()

        if let onInspectCodexConfig {
          Button("Inspect Codex Config") {
            onInspectCodexConfig()
          }
          .buttonStyle(.plain)
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.accent)
        }
      }
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.sm)
    .onChange(of: codexUseOrbitDockOverrides) { _, newValue in
      if newValue, codexModel.isEmpty {
        codexModel = currentCodexModelOption?.model
          ?? codexModels.first(where: \.isDefault)?.model
          ?? codexModels.first(where: { !$0.model.isEmpty })?.model
          ?? ""
      }
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
    if inheritsFromCodexConfig {
      Text("From Codex config")
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(Color.textTertiary)
    } else if !codexModel.isEmpty {
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
