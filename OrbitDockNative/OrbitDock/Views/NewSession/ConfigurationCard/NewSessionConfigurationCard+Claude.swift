import SwiftUI

extension NewSessionConfigurationCard {
  var modelRow: some View {
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
  var claudeModelPicker: some View {
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

  var claudeControlsCluster: some View {
    HStack(alignment: .top, spacing: Spacing.md) {
      claudePermissionCluster
      claudeEffortCluster
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.sm)
  }

  var claudePermissionCluster: some View {
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

  var claudeEffortCluster: some View {
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

  var claudeBypassRow: some View {
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
}
