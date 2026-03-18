import SwiftUI

struct MissionClaudeAgentSection: View {
  @Binding var claudeModel: String
  @Binding var claudeEffort: EffortLevel
  @Binding var claudePermission: ClaudePermissionMode
  @Binding var claudeAllowedTools: String
  @Binding var claudeDisallowedTools: String
  @Binding var claudeAllowBypass: Bool
  let isCompact: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      missionProviderSubheader("Claude", icon: "cpu", color: .providerClaude)

      missionCompactField("Model", placeholder: "claude-sonnet-4-6", text: $claudeModel)

      if isCompact {
        missionEffortRow("Effort", binding: $claudeEffort)
        permissionRow
      } else {
        HStack(alignment: .top, spacing: Spacing.lg) {
          missionEffortRow("Effort", binding: $claudeEffort)
          permissionRow
        }
      }

      bypassRow

      if isCompact {
        missionCompactField("Allowed Tools", placeholder: "Read, Edit, Bash(git:*)", text: $claudeAllowedTools)
        missionCompactField("Disallowed Tools", placeholder: "Bash(rm:*)", text: $claudeDisallowedTools)
      } else {
        HStack(alignment: .top, spacing: Spacing.sm) {
          missionCompactField("Allowed Tools", placeholder: "Read, Edit, Bash(git:*)", text: $claudeAllowedTools)
          missionCompactField("Disallowed Tools", placeholder: "Bash(rm:*)", text: $claudeDisallowedTools)
        }
      }
    }
  }

  private var permissionRow: some View {
    VStack(alignment: .leading, spacing: Spacing.sm_) {
      missionSectionLabel("Permission")

      WrappingFlowLayout(spacing: Spacing.xs) {
        permissionChip(.acceptEdits)
        permissionChip(.bypassPermissions)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func permissionChip(_ mode: ClaudePermissionMode) -> some View {
    let isSelected = claudePermission == mode

    let label: String = isCompact ? {
      switch mode {
        case .plan: "Plan"
        case .dontAsk: "Don't Ask"
        case .default: "Default"
        case .acceptEdits: "Edits"
        case .bypassPermissions: "Bypass"
      }
    }() : mode.displayName

    return Button {
      claudePermission = mode
    } label: {
      SelectableOptionChip(
        label: label,
        icon: mode.icon,
        isSelected: isSelected,
        tint: mode.color,
        isCompact: isCompact
      )
    }
    .buttonStyle(.plain)
  }

  private var bypassRow: some View {
    HStack(spacing: Spacing.sm) {
      Toggle(isOn: $claudeAllowBypass) {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text("Allow Bypass Permissions")
            .font(.system(size: TypeScale.caption, weight: .medium))
            .foregroundStyle(Color.textSecondary)
          Text("Enables mid-session switching to Bypass mode. Required for unattended agents that may need unrestricted tool access.")
            .font(.system(size: TypeScale.micro))
            .foregroundStyle(Color.textQuaternary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .toggleStyle(.switch)
      .tint(Color.autonomyUnrestricted)
    }
  }
}
