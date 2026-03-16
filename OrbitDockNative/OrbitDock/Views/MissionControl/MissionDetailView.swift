import SwiftUI

struct MissionDetailView: View {
  let missionId: String
  let http: ServerHTTPClient

  @Environment(\.dismiss) private var dismiss
  @State private var summary: MissionSummary?
  @State private var issues: [MissionIssueItem] = []
  @State private var isLoading = true

  var body: some View {
    Group {
      if isLoading {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let summary {
        ScrollView {
          VStack(alignment: .leading, spacing: Spacing.lg) {
            missionHeader(summary)
            if !issues.isEmpty {
              pipelineSection
            }
          }
          .padding(Spacing.section)
        }
      }
    }
    .frame(minWidth: 480, minHeight: 400)
    .background(Color.backgroundPrimary)
    .task {
      await fetchDetail()
    }
  }

  @ViewBuilder
  private func missionHeader(_ mission: MissionSummary) -> some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack {
        Text(mission.repoRoot.split(separator: "/").last.map(String.init) ?? mission.repoRoot)
          .font(.system(size: TypeScale.headline, weight: .bold))

        Spacer()

        capsuleTag(mission.trackerKind.capitalized)
        capsuleTag(mission.provider.capitalized)
      }

      HStack(spacing: Spacing.lg) {
        statBadge("Active", count: mission.activeCount, color: .blue)
        statBadge("Queued", count: mission.queuedCount, color: .orange)
        statBadge("Done", count: mission.completedCount, color: .green)
        statBadge("Failed", count: mission.failedCount, color: .red)
      }
    }
  }

  private func capsuleTag(_ text: String) -> some View {
    Text(text)
      .font(.system(size: TypeScale.micro, weight: .semibold))
      .foregroundStyle(Color.textTertiary)
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.xs)
      .background(Color.backgroundTertiary, in: Capsule())
  }

  private func statBadge(_ label: String, count: UInt32, color: Color) -> some View {
    VStack(spacing: Spacing.xs) {
      Text("\(count)")
        .font(.system(size: TypeScale.large, weight: .bold))
        .foregroundStyle(color)
      Text(label)
        .font(.system(size: TypeScale.micro, weight: .medium))
        .foregroundStyle(Color.textTertiary)
    }
  }

  private var pipelineSection: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      Text("Issues")
        .font(.system(size: TypeScale.large, weight: .semibold))
        .foregroundStyle(Color.textPrimary)

      VStack(spacing: Spacing.sm_) {
        ForEach(issues) { issue in
          MissionIssueRow(issue: issue)
        }
      }
    }
  }

  private func fetchDetail() async {
    isLoading = true
    do {
      let response: MissionDetailResponse = try await http.get("/api/missions/\(missionId)")
      summary = response.summary
      issues = response.issues
    } catch {
      // Silently fail for now
    }
    isLoading = false
  }
}

private struct MissionDetailResponse: Codable {
  let summary: MissionSummary
  let issues: [MissionIssueItem]
}
