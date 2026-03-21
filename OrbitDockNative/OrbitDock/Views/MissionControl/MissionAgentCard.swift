import SwiftUI

struct MissionAgentCard: View {
  let issue: MissionIssueItem
  let conversation: DashboardConversationRecord?
  let isCompact: Bool
  let onNavigateToSession: (String) -> Void
  @Binding var expandedIssueId: String?

  private var isExpanded: Bool {
    expandedIssueId == issue.issueId
  }

  private var cardAccent: Color {
    conversation?.displayStatus.color ?? issue.orchestrationState.color
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
      if let conversation {
        SessionStatusBadge(status: conversation.displayStatus, showIcon: true, size: .compact)
      } else {
        Text(issue.orchestrationState.displayLabel)
          .font(.system(size: TypeScale.micro, weight: .semibold))
          .foregroundStyle(issue.orchestrationState.color)
      }

      Spacer()

      Text(issue.provider.capitalized)
        .font(.system(size: TypeScale.micro, weight: .semibold))
        .foregroundStyle(providerColor)

      if let conversation {
        UnifiedModelBadge(model: conversation.model, provider: conversation.provider, size: .mini)
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
    let isLast = conversation?.branch == nil
    return HStack(spacing: Spacing.xs) {
      treeConnector(isLast: isLast)

      Group {
        if let conversation, conversation.displayStatus == .permission, let tool = conversation.pendingToolName {
          HStack(spacing: Spacing.xs) {
            Image(systemName: "lock.fill")
              .font(.system(size: IconScale.xs, weight: .bold))
            Text(tool)
          }
          .foregroundStyle(Color.statusPermission)
        } else if let conversation, conversation.displayStatus == .question {
          HStack(spacing: Spacing.xs) {
            Image(systemName: "questionmark.bubble")
              .font(.system(size: IconScale.xs, weight: .bold))
            Text(conversation.pendingQuestion.map { String($0.prefix(60)) } ?? "Question")
          }
          .foregroundStyle(Color.statusQuestion)
        } else if let tool = conversation?.pendingToolName {
          HStack(spacing: Spacing.xs) {
            Image(systemName: "wrench.fill")
              .font(.system(size: IconScale.xs, weight: .medium))
            Text(tool)
          }
          .foregroundStyle(Color.textTertiary)
        } else if let conversation, conversation.toolCount > 0 {
          HStack(spacing: Spacing.xs) {
            Image(systemName: "hammer")
              .font(.system(size: IconScale.xs, weight: .medium))
            Text("\(conversation.toolCount) tools active")
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
    if let branch = conversation?.branch {
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
        if let conversation, conversation.toolCount > 0 {
          Text("\(conversation.toolCount) tools")
            .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
        }

        if let conversation, conversation.hasTurnDiff {
          metricSeparator
          Text("changes")
            .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
        }

        if let conversation, conversation.activeWorkerCount > 0 {
          metricSeparator
          Text("\(conversation.activeWorkerCount) workers")
            .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
        }

        if let duration = DashboardFormatters.duration(since: conversation?.startedAt) {
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

    VStack(alignment: .leading, spacing: Spacing.sm_) {
      Text("Latest Context")
        .font(.system(size: TypeScale.micro, weight: .semibold))
        .foregroundStyle(Color.textTertiary)

      if let summary = expandedSummaryText {
        Text(summary)
          .font(.system(size: TypeScale.micro))
          .foregroundStyle(Color.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(Spacing.sm)
          .background(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
              .fill(Color.backgroundTertiary)
          )
      } else {
        Text("Session context loading...")
          .font(.system(size: TypeScale.micro))
          .foregroundStyle(Color.textQuaternary)
      }
    }

    if let conversation, let lastMessage = conversation.lastMessage, !lastMessage.isEmpty {
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
      let needsUrgentGlow = conversation?.displayStatus == .permission || conversation?.displayStatus == .question

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

  private var expandedSummaryText: String? {
    if let question = conversation?.pendingQuestion, !question.isEmpty {
      return question
    }

    if let toolName = conversation?.pendingToolName, !toolName.isEmpty {
      if let toolInput = conversation?.pendingToolInput, !toolInput.isEmpty {
        return "\(toolName): \(toolInput)"
      }
      return "Pending tool: \(toolName)"
    }

    if let contextLine = conversation?.contextLine, !contextLine.isEmpty {
      return contextLine
    }

    if let lastMessage = conversation?.lastMessage, !lastMessage.isEmpty {
      return lastMessage
    }

    return nil
  }
}
