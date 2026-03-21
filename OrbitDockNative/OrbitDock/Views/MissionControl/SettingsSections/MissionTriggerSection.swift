import SwiftUI

struct MissionTriggerSection: View {
  @Binding var triggerKind: String
  @Binding var pollInterval: UInt64
  @Binding var editLabels: String
  @Binding var editStates: String
  @Binding var editProject: String
  @Binding var editTeam: String
  let trackerKind: String
  let isCompact: Bool

  private var isGitHub: Bool {
    trackerKind == "github"
  }

  private var projectLabel: String {
    isGitHub ? "Project Number" : "Project"
  }

  private var projectPlaceholder: String {
    isGitHub ? "1" : "PROJ"
  }

  private var teamLabel: String {
    isGitHub ? "Owner" : "Team"
  }

  private var teamPlaceholder: String {
    isGitHub ? "robdel12" : "Engineering"
  }

  private var statesPlaceholder: String {
    isGitHub ? "Ready, Backlog" : "Todo, In Progress"
  }

  private var statesHint: String {
    isGitHub
      ? "Default statuses: Backlog, Ready, In progress, In review, Done"
      : "Common states: Todo, In Progress, Done, Canceled"
  }

  var body: some View {
    missionInstrumentPanel(
      title: "Trigger",
      icon: "antenna.radiowaves.left.and.right",
      description: "When and which issues to process",
      isCompact: isCompact
    ) {
      VStack(alignment: .leading, spacing: Spacing.lg) {
        VStack(alignment: .leading, spacing: Spacing.sm_) {
          missionSectionLabel("Mode")

          HStack(spacing: Spacing.sm) {
            missionModeButton("Polling", icon: "arrow.clockwise", value: "polling", selected: triggerKind) {
              triggerKind = "polling"
            }
            missionModeButton("Manual", icon: "hand.tap", value: "manual_only", selected: triggerKind) {
              triggerKind = "manual_only"
            }
          }
        }

        if triggerKind == "polling" {
          VStack(alignment: .leading, spacing: Spacing.sm_) {
            missionSectionLabel("Poll Interval")

            WrappingFlowLayout(spacing: Spacing.xs) {
              missionIntervalChip("30s", seconds: 30, current: pollInterval) { pollInterval = 30 }
              missionIntervalChip("1m", seconds: 60, current: pollInterval) { pollInterval = 60 }
              missionIntervalChip("5m", seconds: 300, current: pollInterval) { pollInterval = 300 }
              missionIntervalChip("15m", seconds: 900, current: pollInterval) { pollInterval = 900 }
            }
          }
        }

        VStack(alignment: .leading, spacing: Spacing.sm_) {
          missionSectionLabel("Filters")

          if isCompact {
            missionCompactField(projectLabel, placeholder: projectPlaceholder, text: $editProject)
            missionCompactField(teamLabel, placeholder: teamPlaceholder, text: $editTeam)
          } else {
            HStack(alignment: .top, spacing: Spacing.sm) {
              missionCompactField(projectLabel, placeholder: projectPlaceholder, text: $editProject)
              missionCompactField(teamLabel, placeholder: teamPlaceholder, text: $editTeam)
            }
          }

          missionCompactField("Labels", placeholder: "bug, agent-ready", text: $editLabels)
          missionCompactField("States", placeholder: statesPlaceholder, text: $editStates)

          Text(statesHint)
            .font(.system(size: TypeScale.micro))
            .foregroundStyle(Color.textQuaternary)
        }
      }
    }
  }
}
