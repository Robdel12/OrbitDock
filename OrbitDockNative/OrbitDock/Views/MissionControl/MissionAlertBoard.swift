import SwiftUI

struct MissionAlertBoard: View {
  let failedIssues: [MissionIssueItem]
  let missionId: String
  let endpointId: UUID
  let http: ServerHTTPClient?
  let onNavigateToSession: (String) -> Void
  let onRefresh: () async -> Void

  @State private var actionError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      MissionSectionHeader(
        title: "Needs Attention",
        icon: "exclamationmark.triangle.fill",
        color: Color.feedbackNegative,
        count: failedIssues.count,
        urgency: .attention
      )

      ForEach(failedIssues) { issue in
        alertRow(issue)
      }
    }
    .padding(Spacing.lg)
    .background(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .fill(Color.feedbackNegative.opacity(OpacityTier.subtle))
    )
    .shadow(color: Color.feedbackNegative.opacity(OpacityTier.subtle), radius: 6, y: 2)
    .alert("Error", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(actionError ?? "")
    }
  }

  // MARK: - Alert Row

  private func alertRow(_ issue: MissionIssueItem) -> some View {
    HStack(spacing: Spacing.sm) {
      // Left edge bar
      RoundedRectangle(cornerRadius: 1.5, style: .continuous)
        .fill(Color.feedbackNegative)
        .frame(width: EdgeBar.width)

      VStack(alignment: .leading, spacing: Spacing.xs) {
        // Line 1: identifier + title
        HStack(spacing: Spacing.sm_) {
          Text(issue.identifier)
            .font(.system(size: TypeScale.caption, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.feedbackNegative)

          Text(issue.title)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
        }

        // Line 2: Failed badge + error + attempt
        HStack(spacing: Spacing.sm_) {
          Text("Failed")
            .font(.system(size: TypeScale.micro, weight: .bold))
            .foregroundStyle(Color.feedbackNegative)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 1)
            .background(
              Color.feedbackNegative.opacity(OpacityTier.subtle),
              in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
            )

          if let error = issue.error, !error.isEmpty {
            Text(error)
              .font(.system(size: TypeScale.micro))
              .foregroundStyle(Color.textTertiary)
              .fixedSize(horizontal: false, vertical: true)
          }

          if issue.attempt > 1 {
            Text("attempt #\(issue.attempt)")
              .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
              .foregroundStyle(Color.feedbackCaution)
          }
        }

        // Line 3: Provider + Retry button
        HStack(spacing: Spacing.sm) {
          Text(issue.provider.capitalized)
            .font(.system(size: TypeScale.micro, weight: .semibold))
            .foregroundStyle(issue.providerColor)

          Spacer()

          Button {
            Task { await retryIssue(issue) }
          } label: {
            HStack(spacing: Spacing.xs) {
              Text("Retry")
                .font(.system(size: TypeScale.micro, weight: .semibold))
              Image(systemName: "arrow.right")
                .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(Color.accent)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xs)
            .background(
              Color.accent.opacity(OpacityTier.subtle),
              in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            )
          }
          .buttonStyle(.plain)
        }
      }
    }
    .padding(.vertical, Spacing.sm)
  }

  // MARK: - Actions

  private func retryIssue(_ issue: MissionIssueItem) async {
    guard let http else { return }
    do {
      let _: MissionOkResponse = try await http.request(
        path: "/api/missions/\(missionId)/issues/\(issue.issueId)/retry",
        method: "POST"
      )
      await onRefresh()
    } catch {
      actionError = error.localizedDescription
    }
  }
}
