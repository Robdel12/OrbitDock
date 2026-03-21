import SwiftUI

struct MissionOrchestrationSection: View {
  @Binding var maxRetries: UInt32
  @Binding var stallTimeout: UInt64
  @Binding var baseBranch: String
  @Binding var worktreeRootDir: String
  @Binding var stateOnDispatch: String
  @Binding var stateOnComplete: String
  let trackerKind: String
  let repoRoot: String
  let isCompact: Bool

  private var isGitHub: Bool {
    trackerKind == "github"
  }

  private var dispatchStates: [String] {
    isGitHub ? ["In progress", "Ready", "Backlog"] : ["In Progress", "Todo", "Next"]
  }

  private var completeStates: [String] {
    isGitHub ? ["In review", "Done"] : ["In Review", "Done"]
  }

  var body: some View {
    missionInstrumentPanel(
      title: "Orchestration",
      icon: "gearshape.2",
      description: "Retry, timeout, and branch settings",
      isCompact: isCompact
    ) {
      VStack(alignment: .leading, spacing: Spacing.lg) {
        missionConcurrencyStepper("Max Retries", value: $maxRetries, range: 0 ... 10)

        VStack(alignment: .leading, spacing: Spacing.sm_) {
          missionSectionLabel("Stall Timeout")

          WrappingFlowLayout(spacing: Spacing.xs) {
            missionIntervalChip("5m", seconds: 300, current: stallTimeout) { stallTimeout = 300 }
            missionIntervalChip("10m", seconds: 600, current: stallTimeout) { stallTimeout = 600 }
            missionIntervalChip("30m", seconds: 1_800, current: stallTimeout) { stallTimeout = 1_800 }
            missionIntervalChip("1h", seconds: 3_600, current: stallTimeout) { stallTimeout = 3_600 }
          }
        }

        missionCompactField("Base Branch", placeholder: "main", text: $baseBranch)
        missionCompactField(
          "Worktree Root",
          placeholder: ".orbitdock-worktrees (default)",
          text: $worktreeRootDir
        )
        missionStateChips("State on Dispatch", current: $stateOnDispatch, states: dispatchStates)
        missionStateChips("State on Complete", current: $stateOnComplete, states: completeStates)

        HStack(spacing: Spacing.sm_) {
          Image(systemName: "folder")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color.textQuaternary)

          Text(repoRoot)
            .font(.system(size: TypeScale.micro, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
            .fixedSize(horizontal: false, vertical: true)

          #if os(macOS)
            Spacer()

            Button {
              NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: repoRoot)
            } label: {
              Image(systemName: "arrow.up.right.square")
                .font(.system(size: 9))
                .foregroundStyle(Color.textQuaternary)
            }
            .buttonStyle(.plain)
            .help("Reveal in Finder")
          #endif
        }
      }
    }
  }
}
