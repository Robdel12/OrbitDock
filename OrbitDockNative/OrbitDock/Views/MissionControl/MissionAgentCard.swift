import SwiftUI

struct MissionAgentCard: View {
  let issue: MissionIssueItem
  let sessionStore: SessionStore?
  let isCompact: Bool
  let onNavigateToSession: (String) -> Void
  @Binding var expandedIssueId: String?

  private var session: SessionObservable? {
    issue.sessionId.flatMap { sessionStore?.session($0) }
  }

  private var isExpanded: Bool {
    expandedIssueId == issue.issueId
  }

  private var cardAccent: Color {
    session?.displayStatus.color ?? Color.statusWorking
  }

  private var providerColor: Color {
    issue.providerColor
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      issueHeader
      agentStatusLine
      telemetryStack

      if isExpanded {
        expandedContent
      }
    }
    .padding(Spacing.lg)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(cardBackground)
    .contentShape(Rectangle())
    .onTapGesture {
      withAnimation(Motion.standard) {
        expandedIssueId = isExpanded ? nil : issue.issueId
      }
    }
  }

  // MARK: - Issue Header

  private var issueHeader: some View {
    HStack(spacing: Spacing.sm_) {
      Text(issue.identifier)
        .font(.system(size: TypeScale.caption, weight: .bold, design: .monospaced))
        .foregroundStyle(Color.accent)

      Text(issue.title)
        .font(.system(size: TypeScale.caption))
        .foregroundStyle(Color.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: - Agent Status Line

  private var agentStatusLine: some View {
    HStack(spacing: Spacing.sm_) {
      if let session {
        SessionStatusBadge(status: session.displayStatus, showIcon: true, size: .compact)
      } else {
        Text(issue.orchestrationState.displayLabel)
          .font(.system(size: TypeScale.micro, weight: .semibold))
          .foregroundStyle(Color.statusWorking)
      }

      Spacer()

      Text(issue.provider.capitalized)
        .font(.system(size: TypeScale.micro, weight: .semibold))
        .foregroundStyle(providerColor)

      if let session {
        UnifiedModelBadge(model: session.model, provider: session.provider, size: .mini)
      }
    }
  }

  // MARK: - Telemetry Stack

  private var telemetryStack: some View {
    VStack(alignment: .leading, spacing: Spacing.xxs) {
      activityRow
      branchRow
      metricsRow
    }
  }

  private var activityRow: some View {
    let isLast = session?.branch == nil
    return HStack(spacing: Spacing.xs) {
      treeConnector(isLast: isLast)

      Group {
        if let session, session.displayStatus == .permission, let tool = session.pendingToolName {
          HStack(spacing: Spacing.xs) {
            Image(systemName: "lock.fill")
              .font(.system(size: IconScale.xs, weight: .bold))
            Text(tool)
          }
          .foregroundStyle(Color.statusPermission)
        } else if let session, session.displayStatus == .question {
          HStack(spacing: Spacing.xs) {
            Image(systemName: "questionmark.bubble")
              .font(.system(size: IconScale.xs, weight: .bold))
            Text(session.pendingQuestion.map { String($0.prefix(60)) } ?? "Question")
          }
          .foregroundStyle(Color.statusQuestion)
        } else if let tool = session?.lastTool {
          HStack(spacing: Spacing.xs) {
            Image(systemName: "wrench.fill")
              .font(.system(size: IconScale.xs, weight: .medium))
            Text(tool)
          }
          .foregroundStyle(Color.textTertiary)
        } else {
          HStack(spacing: Spacing.xs) {
            Image(systemName: "ellipsis")
              .font(.system(size: IconScale.xs, weight: .medium))
            Text("Initializing...")
          }
          .foregroundStyle(Color.textQuaternary)
        }
      }
      .font(.system(size: TypeScale.micro, weight: .medium))
    }
  }

  @ViewBuilder
  private var branchRow: some View {
    if let branch = session?.branch {
      HStack(spacing: Spacing.xs) {
        treeConnector(isLast: false)

        Image(systemName: "arrow.triangle.branch")
          .font(.system(size: IconScale.xs, weight: .medium))
          .foregroundStyle(Color.textTertiary)

        Text(branch)
          .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.textTertiary)
      }
    }
  }

  private var metricsRow: some View {
    HStack(spacing: Spacing.xs) {
      treeConnector(isLast: true)

      HStack(spacing: 0) {
        if let session, session.totalTokens > 0 {
          Text(DashboardFormatters.tokens(session.totalTokens) + " tok")
            .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
        }

        if let session, !session.turnDiffs.isEmpty {
          metricSeparator
          Text("\(session.turnDiffs.count) edits")
            .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
        }

        if let duration = DashboardFormatters.duration(since: session?.startedAt) {
          metricSeparator
          Text(duration)
            .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
        }
      }

      Spacer()

      if issue.sessionId != nil {
        Button {
          if let sessionId = issue.sessionId {
            onNavigateToSession(sessionId)
          }
        } label: {
          Text("Open \u{2192}")
            .font(.system(size: TypeScale.micro, weight: .semibold))
            .foregroundStyle(Color.accent)
        }
        .buttonStyle(.plain)
      }
    }
  }

  // MARK: - Expanded Content

  @ViewBuilder
  private var expandedContent: some View {
    Divider().foregroundStyle(Color.surfaceBorder)

    // Recent Activity
    VStack(alignment: .leading, spacing: Spacing.sm_) {
      Text("Recent Activity")
        .font(.system(size: TypeScale.micro, weight: .semibold))
        .foregroundStyle(Color.textTertiary)

      if let session, !session.rowEntries.isEmpty {
        let toolRows = recentToolRows(from: session.rowEntries, limit: 5)
        if !toolRows.isEmpty {
          VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(toolRows, id: \.id) { entry in
              recentActivityRow(entry)
            }
          }
          .padding(Spacing.sm)
          .background(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
              .fill(Color.backgroundTertiary)
          )
        } else {
          Text("No tool activity yet")
            .font(.system(size: TypeScale.micro))
            .foregroundStyle(Color.textQuaternary)
        }
      } else {
        Text("Session activity loading...")
          .font(.system(size: TypeScale.micro))
          .foregroundStyle(Color.textQuaternary)
      }
    }

    // Context
    if let session, let lastMessage = session.lastMessage, !lastMessage.isEmpty {
      Text(lastMessage)
        .font(.system(size: TypeScale.micro).italic())
        .foregroundStyle(Color.textTertiary)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }

    // Open Session button
    if let sessionId = issue.sessionId {
      Button {
        onNavigateToSession(sessionId)
      } label: {
        Text("Open Session \u{2192}")
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.accent)
      }
      .buttonStyle(.plain)
    }
  }

  // MARK: - Card Background

  private var cardBackground: some View {
    ZStack(alignment: .leading) {
      let needsUrgentGlow = session?.displayStatus == .permission || session?.displayStatus == .question

      RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
        .fill(Color.backgroundSecondary)
        .overlay(
          RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
            .strokeBorder(
              needsUrgentGlow ? cardAccent.opacity(OpacityTier.medium) : Color.clear,
              lineWidth: 1
            )
        )
        .shadow(
          color: needsUrgentGlow
            ? cardAccent.opacity(OpacityTier.light)
            : cardAccent.opacity(OpacityTier.subtle),
          radius: needsUrgentGlow ? 8 : 4,
          y: 2
        )

      // Left edge bar
      UnevenRoundedRectangle(
        topLeadingRadius: Radius.ml,
        bottomLeadingRadius: Radius.ml,
        bottomTrailingRadius: 0,
        topTrailingRadius: 0
      )
      .fill(cardAccent)
      .frame(width: EdgeBar.width)
    }
  }

  // MARK: - Tree Connector

  private func treeConnector(isLast: Bool) -> some View {
    Text(isLast ? "\u{2514}" : "\u{251C}")
      .font(.system(size: TypeScale.micro, design: .monospaced))
      .foregroundStyle(Color.textQuaternary)
      .frame(width: 12)
  }

  private var metricSeparator: some View {
    Text("  \u{00B7}  ")
      .font(.system(size: TypeScale.micro, design: .monospaced))
      .foregroundStyle(Color.textQuaternary)
  }

  // MARK: - Helpers

  private func recentToolRows(from entries: [ServerConversationRowEntry], limit: Int) -> [ServerConversationRowEntry] {
    let toolEntries = entries.filter { entry in
      if case .tool = entry.row { return true }
      return false
    }
    return Array(toolEntries.suffix(limit))
  }

  private func recentActivityRow(_ entry: ServerConversationRowEntry) -> some View {
    Group {
      if case let .tool(tool) = entry.row {
        HStack(spacing: Spacing.sm_) {
          Image(systemName: toolIcon(for: tool.kind))
            .font(.system(size: IconScale.xs, weight: .medium))
            .foregroundStyle(Color.textTertiary)

          Text(tool.title)
            .font(.system(size: TypeScale.micro, weight: .medium))
            .foregroundStyle(Color.textSecondary)

          if let subtitle = tool.subtitle {
            Text(subtitle)
              .font(.system(size: TypeScale.micro, design: .monospaced))
              .foregroundStyle(Color.textQuaternary)
          }

          Spacer()

          statusIndicator(tool.status)
        }
      }
    }
  }

  private func toolIcon(for kind: ServerConversationToolKind) -> String {
    switch kind {
    case .edit: return "pencil"
    case .read: return "doc.text"
    case .write: return "doc.text.fill"
    case .bash: return "terminal"
    case .grep, .glob: return "magnifyingglass"
    default: return "wrench"
    }
  }

  @ViewBuilder
  private func statusIndicator(_ status: ServerConversationToolStatus) -> some View {
    switch status {
    case .completed:
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: IconScale.xs))
        .foregroundStyle(Color.feedbackPositive)
    case .failed:
      Image(systemName: "xmark.circle.fill")
        .font(.system(size: IconScale.xs))
        .foregroundStyle(Color.feedbackNegative)
    default:
      Image(systemName: "circle")
        .font(.system(size: IconScale.xs))
        .foregroundStyle(Color.textQuaternary)
    }
  }
}
