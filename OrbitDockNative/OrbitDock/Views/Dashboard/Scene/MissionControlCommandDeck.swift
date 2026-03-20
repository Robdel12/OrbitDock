import SwiftUI

struct MissionControlCommandDeck: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(AppRouter.self) private var router

  let conversations: [DashboardConversationRecord]
  @Binding var projectFilter: String?
  let selectedIndex: Int

  private var layoutMode: DashboardLayoutMode {
    DashboardLayoutMode.current(horizontalSizeClass: horizontalSizeClass)
  }

  private var groupedProjects: [ConversationProjectGroup] {
    let groups = Dictionary(grouping: conversations, by: \.groupingPath)

    return groups.compactMap { path, conversations in
      guard let first = conversations.first else { return nil }
      return ConversationProjectGroup(
        path: path,
        name: first.displayProjectName,
        conversations: conversations,
        attentionCount: conversations.filter { $0.displayStatus.needsAttention }.count,
        workingCount: conversations.filter { $0.displayStatus == .working }.count,
        readyCount: conversations.filter { $0.displayStatus == .reply }.count,
        lastActivityAt: conversations.compactMap { $0.lastActivityAt ?? $0.startedAt }.max()
      )
    }
    .sorted(by: sortGroups)
  }

  private var selectedConversationID: String? {
    guard selectedIndex >= 0, selectedIndex < conversations.count else { return nil }
    return conversations[selectedIndex].id
  }

  var body: some View {
    if conversations.isEmpty {
      emptyState
    } else {
      conversationFeed
    }
  }

  private var conversationFeed: some View {
    VStack(alignment: .leading, spacing: Spacing.xl) {
      ForEach(groupedProjects) { group in
        ConversationProjectSection(
          group: group,
          selectedConversationID: selectedConversationID,
          selectedProjectPath: projectFilter,
          layoutMode: layoutMode,
          onFocusProject: {
            projectFilter = projectFilter == group.path ? nil : group.path
          },
          onOpenConversation: selectConversation
        )
      }
    }
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("No conversations in this view")
        .font(.system(size: TypeScale.large, weight: .bold, design: .rounded))
        .foregroundStyle(Color.textPrimary)

      Text("Try another filter or start a new session.")
        .font(.system(size: TypeScale.body))
        .foregroundStyle(Color.textSecondary)
    }
    .padding(Spacing.xl)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
        .fill(Color.backgroundSecondary)
        .overlay(
          RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
            .stroke(Color.surfaceBorder, lineWidth: 1)
        )
    )
  }

  private func selectConversation(_ conversation: DashboardConversationRecord) {
    router.selectSession(conversation.sessionRef, source: .dashboardStream)
  }

  private func sortGroups(lhs: ConversationProjectGroup, rhs: ConversationProjectGroup) -> Bool {
    if lhs.attentionCount != rhs.attentionCount {
      return lhs.attentionCount > rhs.attentionCount
    }
    if lhs.workingCount != rhs.workingCount {
      return lhs.workingCount > rhs.workingCount
    }
    return (lhs.lastActivityAt ?? .distantPast) > (rhs.lastActivityAt ?? .distantPast)
  }
}

// MARK: - Project Grouping

private struct ConversationProjectGroup: Identifiable {
  let path: String
  let name: String
  let conversations: [DashboardConversationRecord]
  let attentionCount: Int
  let workingCount: Int
  let readyCount: Int
  let lastActivityAt: Date?

  var id: String { path }
}

private struct ConversationProjectSection: View {
  let group: ConversationProjectGroup
  let selectedConversationID: String?
  let selectedProjectPath: String?
  let layoutMode: DashboardLayoutMode
  let onFocusProject: () -> Void
  let onOpenConversation: (DashboardConversationRecord) -> Void

  private var isFocused: Bool {
    selectedProjectPath == group.path
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      sectionHeader

      VStack(spacing: 0) {
        ForEach(Array(group.conversations.enumerated()), id: \.element.id) { index, conversation in
          conversationView(for: conversation)

          // Thin divider between compact rows
          if conversation.displayStatus == .reply || conversation.displayStatus == .ended {
            if index < group.conversations.count - 1 {
              Rectangle()
                .fill(Color.surfaceBorder)
                .frame(height: 0.5)
                .padding(.leading, Spacing.lg)
            }
          }
        }
      }
    }
  }

  @ViewBuilder
  private func conversationView(for conversation: DashboardConversationRecord) -> some View {
    let isSelected = selectedConversationID == conversation.id

    switch conversation.displayStatus {
      case .permission, .question:
        AlertConversationCard(
          conversation: conversation,
          isSelected: isSelected,
          layoutMode: layoutMode,
          onOpen: { onOpenConversation(conversation) }
        )
        .padding(.bottom, Spacing.sm)
        .id(DashboardScrollIDs.session(conversation.id))

      case .working:
        ActivityConversationCard(
          conversation: conversation,
          isSelected: isSelected,
          layoutMode: layoutMode,
          onOpen: { onOpenConversation(conversation) }
        )
        .padding(.bottom, Spacing.sm)
        .id(DashboardScrollIDs.session(conversation.id))

      case .reply, .ended:
        CompactConversationRow(
          conversation: conversation,
          isSelected: isSelected,
          layoutMode: layoutMode,
          onOpen: { onOpenConversation(conversation) }
        )
        .id(DashboardScrollIDs.session(conversation.id))
    }
  }

  // MARK: Section Header

  private var sectionHeader: some View {
    HStack(alignment: .center, spacing: Spacing.sm) {
      Text(group.name.uppercased())
        .font(.system(size: TypeScale.caption, weight: .bold))
        .foregroundStyle(Color.textTertiary)
        .tracking(1.5)

      if layoutMode == .desktop {
        stateCluster
      }

      Rectangle()
        .fill(Color.surfaceBorder)
        .frame(height: 0.5)

      focusButton
    }
  }

  private var stateCluster: some View {
    HStack(spacing: Spacing.xs) {
      if group.attentionCount > 0 {
        statePill("\(group.attentionCount) blocked", tint: .statusPermission)
      }
      if group.workingCount > 0 {
        statePill("\(group.workingCount) working", tint: .statusWorking)
      }
      if group.readyCount > 0 {
        statePill("\(group.readyCount) ready", tint: .statusReply)
      }
    }
  }

  private var focusButton: some View {
    Button(isFocused ? "Show all" : "Focus") {
      onFocusProject()
    }
    .buttonStyle(.plain)
    .font(.system(size: TypeScale.caption, weight: .semibold))
    .foregroundStyle(isFocused ? Color.textSecondary : Color.accent)
  }

  private func statePill(_ label: String, tint: Color) -> some View {
    Text(label)
      .font(.system(size: TypeScale.micro, weight: .semibold))
      .foregroundStyle(tint)
      .padding(.horizontal, Spacing.sm_)
      .padding(.vertical, 2)
      .background(
        Capsule(style: .continuous)
          .fill(tint.opacity(OpacityTier.light))
      )
  }
}

// MARK: - Tier 1: Compact Row (Ready / Ended)

private struct CompactConversationRow: View {
  let conversation: DashboardConversationRecord
  let isSelected: Bool
  let layoutMode: DashboardLayoutMode
  let onOpen: () -> Void

  @State private var isHovering = false

  private var hasUnread: Bool { conversation.unreadCount > 0 }

  private var recencyLabel: String? {
    let date = conversation.lastActivityAt ?? conversation.startedAt
    guard let date else { return nil }
    return RelativeClock.shortLabel(for: date)
  }

  private var previewText: String {
    stripMarkdown(
      conversation.lastMessage ?? conversation.contextLine
        ?? "Waiting for your next message."
    )
  }

  var body: some View {
    Button(action: onOpen) {
      HStack(spacing: 0) {
        // Unread accent — thin left indicator
        if hasUnread {
          RoundedRectangle(cornerRadius: 1)
            .fill(Color.accent)
            .frame(width: 2)
            .padding(.vertical, Spacing.xs)
            .padding(.trailing, Spacing.sm)
        }

        VStack(alignment: .leading, spacing: 3) {
          // Line 1: Title + recency
          HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Text(conversation.title)
              .font(.system(size: TypeScale.subhead, weight: hasUnread ? .bold : .medium))
              .foregroundStyle(hasUnread ? Color.textPrimary : Color.textSecondary)
              .lineLimit(1)

            Spacer(minLength: Spacing.xs)

            if let recencyLabel {
              Text(recencyLabel)
                .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.textQuaternary)
            }
          }

          // Line 2: Preview + trailing metadata
          HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(previewText)
              .font(.system(size: TypeScale.caption, weight: .regular))
              .foregroundStyle(Color.textTertiary)
              .lineLimit(1)
              .layoutPriority(-1)

            if layoutMode == .desktop {
              Spacer(minLength: Spacing.md)

              compactMetadata
                .layoutPriority(1)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.leading, hasUnread ? Spacing.lg_ : Spacing.lg)
      .padding(.trailing, Spacing.lg)
      .padding(.vertical, Spacing.md_)
      .background(
        RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
          .fill(isSelected ? Color.surfaceSelected : (isHovering ? Color.surfaceHover : Color.clear))
      )
      .overlay(alignment: .trailing) {
        if isHovering {
          Image(systemName: "chevron.right")
            .font(.system(size: IconScale.sm, weight: .semibold))
            .foregroundStyle(Color.textQuaternary)
            .padding(.trailing, Spacing.sm_)
        }
      }
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
  }

  private var compactMetadata: some View {
    HStack(spacing: Spacing.sm_) {
      if let branch = conversation.branch, !branch.isEmpty {
        Text(truncateBranch(branch, max: 16))
          .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.textQuaternary)
      }

      if let model = conversation.model {
        Text(displayNameForModel(model, provider: conversation.provider))
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(Color.textQuaternary)
      }

      if conversation.hasTurnDiff, let diff = conversation.diffPreview {
        HStack(spacing: Spacing.gap) {
          Text("+\(diff.additions)")
            .foregroundStyle(Color.diffAddedAccent.opacity(0.7))
          Text("−\(diff.deletions)")
            .foregroundStyle(Color.diffRemovedAccent.opacity(0.7))
        }
        .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
      }
    }
  }
}

// MARK: - Tier 2: Activity Card (Working)

private struct ActivityConversationCard: View {
  let conversation: DashboardConversationRecord
  let isSelected: Bool
  let layoutMode: DashboardLayoutMode
  let onOpen: () -> Void

  @State private var isHovering = false

  private var activityLine: String {
    if let toolName = conversation.pendingToolName {
      return "Running \(toolName)"
    }
    return stripMarkdown(
      conversation.lastMessage ?? conversation.contextLine ?? "Processing…"
    )
  }

  private var recencyLabel: String {
    let date = conversation.lastActivityAt ?? conversation.startedAt
    guard let date else { return "now" }
    return RelativeClock.shortLabel(for: date)
  }

  var body: some View {
    Button(action: onOpen) {
      VStack(alignment: .leading, spacing: Spacing.sm_) {
        // Title + recency
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
          Text(conversation.title)
            .font(.system(size: TypeScale.title, weight: .bold))
            .foregroundStyle(Color.textPrimary)
            .lineLimit(1)

          Spacer(minLength: Spacing.xs)

          Text(recencyLabel)
            .font(.system(size: TypeScale.meta, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textTertiary)
        }

        // Activity context
        Text(activityLine)
          .font(.system(size: TypeScale.body, weight: .regular))
          .foregroundStyle(Color.textSecondary)
          .lineLimit(1)

        // Footer: status + metadata
        HStack(spacing: Spacing.sm_) {
          HStack(spacing: Spacing.gap) {
            Image(systemName: "bolt.fill")
              .font(.system(size: IconScale.sm, weight: .bold))
            Text("Working")
              .font(.system(size: TypeScale.meta, weight: .semibold))
          }
          .foregroundStyle(Color.statusWorking)
          .padding(.horizontal, Spacing.sm_)
          .padding(.vertical, 2)
          .background(
            Capsule(style: .continuous)
              .fill(Color.statusWorking.opacity(OpacityTier.light))
          )

          if conversation.activeWorkerCount > 1 {
            Text("\(conversation.activeWorkerCount) workers")
              .font(.system(size: TypeScale.micro, weight: .medium))
              .foregroundStyle(Color.textQuaternary)
          }

          if let branch = conversation.branch, !branch.isEmpty {
            Text(truncateBranch(branch, max: 20))
              .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
              .foregroundStyle(Color.textQuaternary)
          }

          if let model = conversation.model, layoutMode == .desktop {
            Text(displayNameForModel(model, provider: conversation.provider))
              .font(.system(size: TypeScale.micro, weight: .medium))
              .foregroundStyle(Color.textQuaternary)
          }

          if conversation.hasTurnDiff, let diff = conversation.diffPreview {
            Text("+\(diff.additions) −\(diff.deletions)")
              .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
              .foregroundStyle(Color.textQuaternary)
          }

          Spacer(minLength: Spacing.sm)

          if layoutMode == .desktop {
            Text("Open")
              .font(.system(size: TypeScale.caption, weight: .semibold))
              .foregroundStyle(Color.accent)
          }
        }
      }
      .padding(.horizontal, Spacing.lg)
      .padding(.vertical, Spacing.lg_)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(cardBackground)
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
  }

  private var cardBackground: some View {
    RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
      .fill(Color.backgroundTertiary.opacity(isHovering || isSelected ? 1.0 : 0.85))
      .overlay(
        RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
          .stroke(
            Color.statusWorking.opacity(isHovering || isSelected ? 0.30 : 0.18),
            lineWidth: isSelected ? 1.4 : 1
          )
      )
      .shadow(color: Color.statusWorking.opacity(0.12), radius: 8, y: 0)
      .shadow(color: Color.statusWorking.opacity(0.06), radius: 3, y: 0)
  }
}

// MARK: - Tier 3: Alert Card (Permission / Question)

private struct AlertConversationCard: View {
  let conversation: DashboardConversationRecord
  let isSelected: Bool
  let layoutMode: DashboardLayoutMode
  let onOpen: () -> Void

  @State private var isHovering = false

  private var statusColor: Color { conversation.displayStatus.color }

  private var contextText: String {
    if let pendingQuestion = conversation.pendingQuestion, !pendingQuestion.isEmpty {
      return pendingQuestion
    }
    if let pendingToolName = conversation.pendingToolName {
      if let pendingToolInput = conversation.pendingToolInput, !pendingToolInput.isEmpty {
        return "Wants to run \(pendingToolName): \(pendingToolInput)"
      }
      return "Wants to run \(pendingToolName)"
    }
    return stripMarkdown(
      conversation.lastMessage ?? conversation.contextLine
        ?? "Needs your attention."
    )
  }

  private var statusIcon: String {
    conversation.displayStatus == .permission ? "lock.fill" : "questionmark.bubble.fill"
  }

  private var statusLabel: String {
    conversation.displayStatus == .permission ? "Approval" : "Question"
  }

  private var recencyLabel: String {
    let date = conversation.lastActivityAt ?? conversation.startedAt
    guard let date else { return "now" }
    return RelativeClock.shortLabel(for: date)
  }

  var body: some View {
    Button(action: onOpen) {
      VStack(alignment: .leading, spacing: Spacing.md_) {
        // Title + recency
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
          Text(conversation.title)
            .font(.system(size: TypeScale.large, weight: .bold))
            .foregroundStyle(Color.textPrimary)
            .lineLimit(1)

          Spacer(minLength: Spacing.xs)

          Text(recencyLabel)
            .font(.system(size: TypeScale.meta, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.textTertiary)
        }

        // Pending context — the reason this card is big
        Text(contextText)
          .font(.system(size: TypeScale.body, weight: .medium))
          .foregroundStyle(Color.textSecondary)
          .lineLimit(3)
          .frame(maxWidth: .infinity, alignment: .leading)

        // Footer: status badge + metadata
        HStack(spacing: Spacing.sm_) {
          HStack(spacing: Spacing.gap) {
            Image(systemName: statusIcon)
              .font(.system(size: IconScale.sm, weight: .bold))
            Text(statusLabel)
              .font(.system(size: TypeScale.meta, weight: .semibold))
          }
          .foregroundStyle(statusColor)
          .padding(.horizontal, Spacing.sm_)
          .padding(.vertical, 2)
          .background(
            Capsule(style: .continuous)
              .fill(statusColor.opacity(OpacityTier.light))
          )

          if let branch = conversation.branch, !branch.isEmpty {
            Text(truncateBranch(branch, max: 20))
              .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
              .foregroundStyle(Color.textQuaternary)
          }

          if let model = conversation.model, layoutMode == .desktop {
            Text(displayNameForModel(model, provider: conversation.provider))
              .font(.system(size: TypeScale.micro, weight: .medium))
              .foregroundStyle(Color.textQuaternary)
          }

          if conversation.hasTurnDiff, let diff = conversation.diffPreview {
            Text("+\(diff.additions) −\(diff.deletions)")
              .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
              .foregroundStyle(Color.textQuaternary)
          }

          Spacer(minLength: Spacing.sm)

          if layoutMode == .desktop {
            Text("Open")
              .font(.system(size: TypeScale.caption, weight: .semibold))
              .foregroundStyle(Color.accent)
          }
        }
      }
      .padding(.horizontal, Spacing.lg)
      .padding(.vertical, Spacing.lg)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(cardBackground)
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
  }

  private var cardBackground: some View {
    RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
      .fill(Color.backgroundTertiary.opacity(isHovering || isSelected ? 1.0 : 0.90))
      .overlay(
        RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
          .stroke(
            statusColor.opacity(isHovering || isSelected ? 0.40 : 0.25),
            lineWidth: isSelected ? 1.6 : 1.2
          )
      )
      // Layered glow — outer diffuse + inner tight
      .shadow(color: statusColor.opacity(0.20), radius: 14, y: 0)
      .shadow(color: statusColor.opacity(0.10), radius: 5, y: 0)
  }
}

// MARK: - Shared Utilities

private func truncateBranch(_ branch: String, max: Int) -> String {
  if branch.count <= max { return branch }
  return "\(branch.prefix(max - 1))…"
}

private func stripMarkdown(_ text: String) -> String {
  text
    .replacingOccurrences(of: "**", with: "")
    .replacingOccurrences(of: "__", with: "")
    .replacingOccurrences(of: "`", with: "")
    .replacingOccurrences(of: "## ", with: "")
    .replacingOccurrences(of: "# ", with: "")
}

private enum RelativeClock {
  static func shortLabel(for date: Date, now: Date = .now) -> String {
    let interval = max(0, now.timeIntervalSince(date))
    if interval < 60 { return "now" }
    if interval < 3600 { return "\(Int(interval / 60))m" }
    if interval < 86_400 { return "\(Int(interval / 3600))h" }
    return "\(Int(interval / 86_400))d"
  }
}
