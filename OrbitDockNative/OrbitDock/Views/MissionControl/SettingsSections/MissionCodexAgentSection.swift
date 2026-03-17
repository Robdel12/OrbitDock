import SwiftUI

struct MissionCodexAgentSection: View {
  @Binding var codexModel: String
  @Binding var codexEffort: EffortLevel
  @Binding var codexAutonomy: AutonomyLevel
  @Binding var codexMultiAgent: Bool
  @Binding var codexCollaboration: CodexCollaborationMode
  @Binding var codexDevInstructions: String
  let isCompact: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.lg) {
      missionProviderSubheader("Codex", icon: "terminal", color: .providerCodex)

      missionCompactField("Model", placeholder: "gpt-5.3-codex", text: $codexModel)

      if isCompact {
        missionEffortRow("Effort", binding: $codexEffort)
        autonomyRow
      } else {
        HStack(alignment: .top, spacing: Spacing.lg) {
          missionEffortRow("Effort", binding: $codexEffort)
          autonomyRow
        }
      }

      if isCompact {
        multiAgentToggleRow
        collaborationRow
      } else {
        HStack(alignment: .top, spacing: Spacing.lg) {
          collaborationRow
          multiAgentToggleRow
        }
      }

      missionCompactField("Developer Instructions", placeholder: "Be concise and pragmatic", text: $codexDevInstructions)
    }
  }

  private var autonomyRow: some View {
    VStack(alignment: .leading, spacing: Spacing.sm_) {
      missionSectionLabel("Autonomy")

      WrappingFlowLayout(spacing: Spacing.xs) {
        autonomyChip(.autonomous)
        autonomyChip(.fullAuto)
        autonomyChip(.open)
        autonomyChip(.unrestricted)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var multiAgentToggleRow: some View {
    VStack(alignment: .leading, spacing: Spacing.sm_) {
      missionSectionLabel("Multi-Agent")

      HStack(spacing: Spacing.sm) {
        Toggle("", isOn: $codexMultiAgent)
          .labelsHidden()
          .toggleStyle(.switch)
          .controlSize(.mini)

        Text(codexMultiAgent ? "Enabled" : "Disabled")
          .font(.system(size: TypeScale.caption, weight: .medium))
          .foregroundStyle(codexMultiAgent ? Color.accent : Color.textQuaternary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var collaborationRow: some View {
    VStack(alignment: .leading, spacing: Spacing.sm_) {
      missionSectionLabel("Collaboration")

      HStack(spacing: Spacing.sm) {
        collaborationButton(.default)
        collaborationButton(.plan)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func autonomyChip(_ level: AutonomyLevel) -> some View {
    let isSelected = codexAutonomy == level

    let label: String = isCompact ? {
      switch level {
        case .locked: "Locked"
        case .guarded: "Guard"
        case .autonomous: "Auto"
        case .fullAuto: "Full"
        case .open: "Open"
        case .unrestricted: "None"
      }
    }() : level.displayName

    return Button {
      codexAutonomy = level
    } label: {
      SelectableOptionChip(
        label: label,
        icon: level.icon,
        isSelected: isSelected,
        tint: level.color,
        isCompact: isCompact
      )
    }
    .buttonStyle(.plain)
  }

  private func collaborationButton(_ mode: CodexCollaborationMode) -> some View {
    let isSelected = codexCollaboration == mode

    return Button {
      withAnimation(Motion.snappy) { codexCollaboration = mode }
    } label: {
      SelectableOptionChip(
        label: mode.displayName,
        icon: mode.icon,
        isSelected: isSelected,
        tint: mode.color
      )
    }
    .buttonStyle(.plain)
  }
}
