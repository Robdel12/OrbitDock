import SwiftUI

struct MissionAlertBoard: View {
  let failedIssues: [MissionIssueItem]
  let blockedIssues: [MissionIssueItem]
  let missionId: String
  let endpointId: UUID
  let http: ServerHTTPClient?
  let isCompact: Bool
  let onNavigateToSession: (String) -> Void
  let onRefresh: () async -> Void

  @State private var actionError: String?

  private var allAlertIssues: [MissionIssueItem] {
    blockedIssues + failedIssues
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      MissionSectionHeader(
        title: "Needs Attention",
        icon: "exclamationmark.triangle.fill",
        color: Color.feedbackNegative,
        count: allAlertIssues.count,
        urgency: .attention
      )

      ForEach(allAlertIssues) { issue in
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
    let isBlocked = issue.orchestrationState == .blocked
    let alertColor = isBlocked ? Color.feedbackWarning : Color.feedbackNegative

    return HStack(spacing: Spacing.sm) {
      // Left edge bar
      RoundedRectangle(cornerRadius: 1.5, style: .continuous)
        .fill(alertColor)
        .frame(width: EdgeBar.width)

      VStack(alignment: .leading, spacing: Spacing.xs) {
        if isCompact {
          // Compact: identifier + badge on first line, title below
          HStack(spacing: Spacing.sm_) {
            Text(issue.identifier)
              .font(.system(size: TypeScale.micro, weight: .bold, design: .monospaced))
              .foregroundStyle(alertColor)

            Text(isBlocked ? "Blocked" : "Failed")
              .font(.system(size: TypeScale.micro, weight: .bold))
              .foregroundStyle(alertColor)
              .padding(.horizontal, Spacing.xs)
              .padding(.vertical, 1)
              .background(
                alertColor.opacity(OpacityTier.subtle),
                in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
              )

            if issue.attempt > 1 {
              Text("#\(issue.attempt)")
                .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.feedbackCaution)
            }

            Spacer()

            if let urlString = issue.url, let url = URL(string: urlString) {
              Button {
                _ = Platform.services.openURL(url)
              } label: {
                Image(systemName: "arrow.up.right.square")
                  .font(.system(size: 10, weight: .medium))
                  .foregroundStyle(Color.accent)
              }
              .buttonStyle(.plain)
            }

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

          Text(issue.title)
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textPrimary)
            .fixedSize(horizontal: false, vertical: true)

          if let error = issue.error, !error.isEmpty {
            Text(error)
              .font(.system(size: TypeScale.micro))
              .foregroundStyle(Color.textTertiary)
              .lineLimit(2)
          }
        } else {
          // Desktop: original 3-line layout
          HStack(spacing: Spacing.sm_) {
            Text(issue.identifier)
              .font(.system(size: TypeScale.caption, weight: .bold, design: .monospaced))
              .foregroundStyle(alertColor)

            Text(issue.title)
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.textPrimary)
              .fixedSize(horizontal: false, vertical: true)
          }

          HStack(spacing: Spacing.sm_) {
            Text(isBlocked ? "Blocked" : "Failed")
              .font(.system(size: TypeScale.micro, weight: .bold))
              .foregroundStyle(alertColor)
              .padding(.horizontal, Spacing.xs)
              .padding(.vertical, 1)
              .background(
                alertColor.opacity(OpacityTier.subtle),
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

          HStack(spacing: Spacing.sm) {
            Text(issue.provider.capitalized)
              .font(.system(size: TypeScale.micro, weight: .semibold))
              .foregroundStyle(issue.providerColor)

            Spacer()

            if let urlString = issue.url, let url = URL(string: urlString) {
              Button {
                _ = Platform.services.openURL(url)
              } label: {
                Image(systemName: "arrow.up.right.square")
                  .font(.system(size: 10, weight: .medium))
                  .foregroundStyle(Color.accent)
              }
              .buttonStyle(.plain)
              .help("Open in tracker")
            }

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
