import SwiftUI

struct MissionActiveThreads: View {
  let runningIssues: [MissionIssueItem]
  let missionId: String
  let settings: MissionSettings?
  let isCompact: Bool
  let sessionStore: SessionStore?
  let http: ServerHTTPClient?
  let onRefresh: () async -> Void
  let onNavigateToSession: (String) -> Void

  @State private var actionError: String?

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      MissionSectionHeader(
        title: "Active Threads",
        icon: "bolt.fill",
        color: Color.statusWorking,
        trailing: settings.map { "\(runningIssues.count) of \($0.provider.maxConcurrent)" }
      )

      let layout = isCompact
        ? AnyLayout(VStackLayout(spacing: Spacing.sm))
        : AnyLayout(HStackLayout(alignment: .top, spacing: Spacing.sm))

      layout {
        ForEach(runningIssues) { issue in
          agentCard(issue)
        }
      }
    }
    .alert("Error", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(actionError ?? "")
    }
  }

  // MARK: - Agent Card

  private func agentCard(_ issue: MissionIssueItem) -> some View {
    let session = issue.sessionId.flatMap { sessionStore?.session($0) }
    let hasSessionData = session?.model != nil
    let sessionStatus = hasSessionData ? session?.displayStatus : nil
    let cardAccent: Color = sessionStatus?.color ?? Color.statusWorking
    let providerColor: Color = issue.provider == "codex" ? Color.feedbackPositive : Color.accent

    return VStack(alignment: .leading, spacing: Spacing.sm) {
      // Header: identifier + provider badge
      HStack(spacing: Spacing.sm_) {
        Circle()
          .fill(cardAccent)
          .frame(width: 6, height: 6)

        Text(issue.identifier)
          .font(.system(size: TypeScale.caption, weight: .bold, design: .monospaced))
          .foregroundStyle(Color.accent)

        Spacer()

        Text(issue.provider.capitalized)
          .font(.system(size: TypeScale.micro, weight: .semibold))
          .foregroundStyle(providerColor)
          .padding(.horizontal, Spacing.sm_)
          .padding(.vertical, 2)
          .background(
            providerColor.opacity(OpacityTier.subtle),
            in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
          )
      }

      // Title
      Text(issue.title)
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.textSecondary)
        .lineLimit(2)

      // Tracker state + attempt
      HStack(spacing: Spacing.sm_) {
        Text(issue.trackerState)
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(Color.textQuaternary)
          .padding(.horizontal, Spacing.xs)
          .padding(.vertical, 1)
          .background(
            Color.backgroundTertiary,
            in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
          )

        if issue.attempt > 1 {
          Text("attempt #\(issue.attempt)")
            .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.feedbackCaution)
        }

        Spacer()
      }

      // Actions
      Divider().foregroundStyle(Color.surfaceBorder)

      HStack(spacing: Spacing.sm) {
        Button {
          Task { await retryIssue(issue) }
        } label: {
          HStack(spacing: Spacing.xxs) {
            Image(systemName: "arrow.clockwise")
              .font(.system(size: 9, weight: .bold))
            Text("Restart")
              .font(.system(size: TypeScale.micro, weight: .medium))
          }
          .foregroundStyle(Color.feedbackCaution)
        }
        .buttonStyle(.plain)

        Spacer()

        // Session Preview
        if let session, hasSessionData {
          sessionPreview(session)
        } else if issue.sessionId != nil {
          HStack(spacing: Spacing.xxs) {
            Text("Session")
              .font(.system(size: TypeScale.micro, weight: .medium))
            Image(systemName: "arrow.right")
              .font(.system(size: 8, weight: .bold))
          }
          .foregroundStyle(Color.accent)
        }
      }
    }
    .padding(Spacing.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
        .fill(Color.backgroundSecondary)
        .overlay(
          RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
            .strokeBorder(cardAccent.opacity(OpacityTier.light), lineWidth: 1)
        )
    )
    .shadow(color: cardAccent.opacity(OpacityTier.subtle), radius: 8, y: 2)
    .contentShape(Rectangle())
    .onTapGesture {
      if let sessionId = issue.sessionId {
        onNavigateToSession(sessionId)
      } else if let url = issue.url, let link = URL(string: url) {
        #if os(macOS)
          NSWorkspace.shared.open(link)
        #endif
      }
    }
  }

  // MARK: - Session Preview

  private func sessionPreview(_ session: SessionObservable) -> some View {
    let status = session.displayStatus

    return VStack(alignment: .leading, spacing: Spacing.sm_) {
      // Row 1: Status badge + Branch + Model
      HStack(spacing: Spacing.sm) {
        SessionStatusBadge(status: status, showIcon: true, size: .compact)

        if let branch = session.branch {
          HStack(spacing: Spacing.xxs) {
            Image(systemName: "arrow.triangle.branch")
              .font(.system(size: 8, weight: .medium))
            Text(branch.count > 20 ? String(branch.prefix(18)) + "\u{2026}" : branch)
          }
          .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.textTertiary)
        }

        Spacer()

        UnifiedModelBadge(model: session.model, provider: session.provider, size: .mini)
      }

      // Row 2: Tool activity + Tokens
      HStack(spacing: Spacing.sm) {
        if status == .permission, let tool = session.pendingToolName {
          HStack(spacing: Spacing.xs) {
            Image(systemName: "lock.fill")
              .font(.system(size: 8, weight: .bold))
            Text(tool)
              .lineLimit(1)
          }
          .font(.system(size: TypeScale.micro, weight: .semibold))
          .foregroundStyle(status.color)
        } else if status == .question {
          HStack(spacing: Spacing.xs) {
            Image(systemName: "questionmark.bubble")
              .font(.system(size: 8, weight: .bold))
            Text(session.pendingQuestion.map { String($0.prefix(50)) } ?? "Question")
              .lineLimit(1)
          }
          .font(.system(size: TypeScale.micro, weight: .semibold))
          .foregroundStyle(status.color)
        } else if let tool = session.lastTool {
          HStack(spacing: Spacing.xs) {
            Image(systemName: "wrench.fill")
              .font(.system(size: 8, weight: .medium))
            Text(tool)
              .lineLimit(1)
          }
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(Color.textTertiary)
        }

        Spacer()

        if session.totalTokens > 0 {
          Text(formatTokenCount(session.totalTokens))
            .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
        }
      }
    }
  }

  private func formatTokenCount(_ tokens: Int) -> String {
    if tokens >= 1_000_000 {
      return String(format: "%.1fM tok", Double(tokens) / 1_000_000)
    } else if tokens >= 1_000 {
      return String(format: "%.1fk tok", Double(tokens) / 1_000)
    }
    return "\(tokens) tok"
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
