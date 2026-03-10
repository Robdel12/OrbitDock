import SwiftUI

struct NewSessionConfigurationCard: View {
  let provider: SessionProvider
  let claudeModels: [ServerClaudeModelOption]
  let codexModels: [ServerCodexModelOption]
  @Binding var claudeModelId: String
  @Binding var customModelInput: String
  @Binding var useCustomModel: Bool
  @Binding var selectedPermissionMode: ClaudePermissionMode
  @Binding var selectedEffort: ClaudeEffortLevel
  @Binding var codexModel: String
  @Binding var selectedAutonomy: AutonomyLevel

  var body: some View {
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
}
