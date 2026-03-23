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

  private var hasMultipleEndpoints: Bool {
    Set(conversations.map(\.sessionRef.endpointId)).count > 1
  }

  private var groupedProjects: [ConversationProjectGroup] {
    // Group by (project path, endpoint) so same project on different servers stays separate
    let groups = Dictionary(grouping: conversations) { conv in
      ConversationGroupKey(path: conv.groupingPath, endpointId: conv.sessionRef.endpointId)
    }

    return groups.compactMap { key, conversations in
      guard let first = conversations.first else { return nil }
      return ConversationProjectGroup(
        path: key.path,
        endpointId: key.endpointId,
        endpointName: first.endpointName,
        name: first.displayProjectName,
        conversations: conversations,
        attentionCount: conversations.filter(\.displayStatus.needsAttention).count,
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
          showEndpointName: hasMultipleEndpoints,
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
      Text("All clear")
        .font(.system(size: TypeScale.large, weight: .bold, design: .rounded))
        .foregroundStyle(Color.textPrimary)

      Text("No active conversations in this view. Start a session or adjust your filters.")
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

private struct ConversationGroupKey: Hashable {
  let path: String
  let endpointId: UUID
}

private struct ConversationProjectGroup: Identifiable {
  let path: String
  let endpointId: UUID
  let endpointName: String?
  let name: String
  let conversations: [DashboardConversationRecord]
  let attentionCount: Int
  let workingCount: Int
  let readyCount: Int
  let lastActivityAt: Date?

  var id: String {
    "\(path)::\(endpointId.uuidString)"
  }

  /// The most urgent status color in this group — used for the section signal dot
  var signalColor: Color {
    if attentionCount > 0 { return .statusPermission }
    if workingCount > 0 { return .statusWorking }
    return .statusReply
  }
}

private struct ConversationProjectSection: View {
  let group: ConversationProjectGroup
  let showEndpointName: Bool
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
          showEndpointName: showEndpointName,
          layoutMode: layoutMode,
          onOpen: { onOpenConversation(conversation) }
        )
        .padding(.bottom, Spacing.sm)
        .id(DashboardScrollIDs.session(conversation.id))

      case .working:
        ActivityConversationCard(
          conversation: conversation,
          isSelected: isSelected,
          showEndpointName: showEndpointName,
          layoutMode: layoutMode,
          onOpen: { onOpenConversation(conversation) }
        )
        .padding(.bottom, Spacing.sm)
        .id(DashboardScrollIDs.session(conversation.id))

      case .reply, .ended:
        CompactConversationRow(
          conversation: conversation,
          isSelected: isSelected,
          showEndpointName: showEndpointName,
          layoutMode: layoutMode,
          onOpen: { onOpenConversation(conversation) }
        )
        .id(DashboardScrollIDs.session(conversation.id))
    }
  }

  // MARK: Section Header — sector label with signal dot + station callsign

  private var sectionHeader: some View {
    HStack(alignment: .center, spacing: Spacing.sm_) {
      // Signal dot — reflects the most urgent status in this group
      Circle()
        .fill(group.signalColor)
        .frame(width: 6, height: 6)
        .shadow(color: group.signalColor.opacity(0.5), radius: 4, y: 0)

      Text(group.name.uppercased())
        .font(.system(size: TypeScale.caption, weight: .bold))
        .foregroundStyle(Color.textTertiary)
        .tracking(1.5)

      // Station callsign — which server this group is from
      if showEndpointName, let endpointName = group.endpointName {
        HStack(spacing: Spacing.gap) {
          Image(systemName: "antenna.radiowaves.left.and.right")
            .font(.system(size: IconScale.xs, weight: .semibold))
          Text(endpointName)
            .font(.system(size: TypeScale.micro, weight: .semibold))
        }
        .foregroundStyle(Color.textQuaternary)
        .padding(.horizontal, Spacing.sm_)
        .padding(.vertical, 1)
        .background(
          Capsule(style: .continuous)
            .fill(Color.surfaceHover.opacity(0.6))
        )
      }

      if layoutMode.isPhoneCompact {
        compactStateIndicator
      } else {
        stateCluster
      }

      // Scanline divider
      Rectangle()
        .fill(
          LinearGradient(
            colors: [Color.surfaceBorder, Color.surfaceBorder.opacity(0.3)],
            startPoint: .leading,
            endPoint: .trailing
          )
        )
        .frame(height: 0.5)

      focusButton
    }
  }

  /// Phone-compact: just colored count dots — no labels
  private var compactStateIndicator: some View {
    HStack(spacing: Spacing.xs) {
      if group.attentionCount > 0 {
        compactCountBadge("\(group.attentionCount)", tint: .statusPermission)
      }
      if group.workingCount > 0 {
        compactCountBadge("\(group.workingCount)", tint: .statusWorking)
      }
    }
  }

  private func compactCountBadge(_ count: String, tint: Color) -> some View {
    Text(count)
      .font(.system(size: TypeScale.mini, weight: .bold, design: .monospaced))
      .foregroundStyle(tint)
      .frame(minWidth: 14)
      .padding(.horizontal, 3)
      .padding(.vertical, 1)
      .background(
        Capsule(style: .continuous)
          .fill(tint.opacity(OpacityTier.light))
      )
  }

  private var stateCluster: some View {
    HStack(spacing: Spacing.xs) {
      if group.attentionCount > 0 {
        statePill("\(group.attentionCount) blocked", tint: .statusPermission)
      }
      if group.workingCount > 0 {
        statePill("\(group.workingCount) in orbit", tint: .statusWorking)
      }
      if group.readyCount > 0 {
        statePill("\(group.readyCount) docked", tint: .statusReply)
      }
    }
  }

  private var focusButton: some View {
    Button(isFocused ? "Show all" : "Track") {
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
  let showEndpointName: Bool
  let layoutMode: DashboardLayoutMode
  let onOpen: () -> Void

  @State private var isHovering = false

  private var hasUnread: Bool {
    conversation.unreadCount > 0
  }

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
      VStack(alignment: .leading, spacing: 3) {
        // Line 1: Title + recency
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
          Text(conversation.title)
            .font(.system(size: TypeScale.subhead, weight: hasUnread ? .bold : .medium))
            .foregroundStyle(hasUnread ? Color.textPrimary : Color.textSecondary)
            .lineLimit(1)

          if let integrationMode = conversation.integrationMode {
            conversationCapabilityBadge(for: integrationMode)
          }

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

          if !layoutMode.isPhoneCompact {
            Spacer(minLength: Spacing.md)

            compactMetadata
              .layoutPriority(1)
          }
        }
      }
      .padding(.horizontal, Spacing.lg)
      .padding(.vertical, Spacing.md_)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(compactBackground)
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
    .modifier(DashboardConversationActionsModifier(conversation: conversation))
    .onHover { isHovering = $0 }
  }

  private var compactBackground: some View {
    RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
      .fill(rowFill)
      .shadow(
        color: hasUnread ? Color.accent.opacity(0.06) : Color.clear,
        radius: hasUnread ? 6 : 0,
        y: 0
      )
  }

  private var rowFill: Color {
    if isSelected { return Color.surfaceSelected }
    if isHovering { return Color.surfaceHover }
    // Unread rows get a barely-visible ambient glow tint
    if hasUnread { return Color.accent.opacity(OpacityTier.tint) }
    return Color.clear
  }

  private var compactMetadata: some View {
    HStack(spacing: Spacing.sm_) {
      if showEndpointName, let name = conversation.endpointName {
        endpointTag(name)
      }

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

      diffLabel(for: conversation)
    }
  }
}

// MARK: - Tier 2: Activity Card (Working)

private struct ActivityConversationCard: View {
  let conversation: DashboardConversationRecord
  let isSelected: Bool
  let showEndpointName: Bool
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

          if let integrationMode = conversation.integrationMode {
            conversationCapabilityBadge(for: integrationMode)
          }

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
            Image(systemName: "antenna.radiowaves.left.and.right")
              .font(.system(size: IconScale.sm, weight: .bold))
            Text("In orbit")
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

          if showEndpointName, let name = conversation.endpointName {
            endpointTag(name)
          }

          if let branch = conversation.branch, !branch.isEmpty {
            Text(truncateBranch(branch, max: 20))
              .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
              .foregroundStyle(Color.textQuaternary)
          }

          if let model = conversation.model, !layoutMode.isPhoneCompact {
            Text(displayNameForModel(model, provider: conversation.provider))
              .font(.system(size: TypeScale.micro, weight: .medium))
              .foregroundStyle(Color.textQuaternary)
          }

          diffLabel(for: conversation)

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
    .modifier(DashboardConversationActionsModifier(conversation: conversation))
    .onHover { isHovering = $0 }
  }

  private var cardBackground: some View {
    ZStack {
      // Base fill with subtle cyan bleed
      RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
        .fill(Color.backgroundTertiary)

      // Gradient overlay — instrument backlighting effect
      RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
        .fill(
          LinearGradient(
            colors: [
              Color.statusWorking.opacity(isHovering ? 0.06 : 0.03),
              Color.clear,
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )

      // Border
      RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
        .stroke(
          Color.statusWorking.opacity(isHovering || isSelected ? 0.30 : 0.18),
          lineWidth: isSelected ? 1.4 : 1
        )
    }
    // Dual glow — outer atmospheric + inner tight
    .shadow(color: Color.statusWorking.opacity(0.14), radius: 10, y: 0)
    .shadow(color: Color.statusWorking.opacity(0.08), radius: 3, y: 0)
  }
}

// MARK: - Tier 3: Alert Card (Permission / Question)

private struct AlertConversationCard: View {
  let conversation: DashboardConversationRecord
  let isSelected: Bool
  let showEndpointName: Bool
  let layoutMode: DashboardLayoutMode
  let onOpen: () -> Void

  @State private var isHovering = false

  private var statusColor: Color {
    conversation.displayStatus.color
  }

  private var contextText: String {
    if let pendingQuestion = conversation.pendingQuestion, !pendingQuestion.isEmpty {
      return pendingQuestion
    }
    if let pendingToolName = conversation.pendingToolName {
      return formatToolContext(toolName: pendingToolName, input: conversation.pendingToolInput)
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

          if let integrationMode = conversation.integrationMode {
            conversationCapabilityBadge(for: integrationMode)
          }

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

          if showEndpointName, let name = conversation.endpointName {
            endpointTag(name)
          }

          if let branch = conversation.branch, !branch.isEmpty {
            Text(truncateBranch(branch, max: 20))
              .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
              .foregroundStyle(Color.textQuaternary)
          }

          if let model = conversation.model, !layoutMode.isPhoneCompact {
            Text(displayNameForModel(model, provider: conversation.provider))
              .font(.system(size: TypeScale.micro, weight: .medium))
              .foregroundStyle(Color.textQuaternary)
          }

          diffLabel(for: conversation)

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
    .modifier(DashboardConversationActionsModifier(conversation: conversation))
    .onHover { isHovering = $0 }
  }

  private var cardBackground: some View {
    ZStack {
      // Base
      RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
        .fill(Color.backgroundTertiary)

      // Radial beacon glow — emanates from top-left like a signal source
      RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
        .fill(
          RadialGradient(
            colors: [
              statusColor.opacity(isHovering ? 0.10 : 0.06),
              Color.clear,
            ],
            center: .topLeading,
            startRadius: 0,
            endRadius: 300
          )
        )

      // Border
      RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
        .stroke(
          statusColor.opacity(isHovering || isSelected ? 0.40 : 0.25),
          lineWidth: isSelected ? 1.6 : 1.2
        )
    }
    // Beacon glow — strong outer + tight inner
    .shadow(color: statusColor.opacity(0.22), radius: 16, y: 0)
    .shadow(color: statusColor.opacity(0.12), radius: 5, y: 0)
  }
}

// MARK: - Shared Components

/// Colored diff stats label — green additions, red deletions
@ViewBuilder
private func diffLabel(for conversation: DashboardConversationRecord) -> some View {
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

// MARK: - Shared Components

/// Endpoint station tag — small muted capsule with antenna icon
private func endpointTag(_ name: String) -> some View {
  HStack(spacing: 2) {
    Image(systemName: "server.rack")
      .font(.system(size: IconScale.xs, weight: .medium))
    Text(name)
      .font(.system(size: TypeScale.micro, weight: .medium))
  }
  .foregroundStyle(Color.textQuaternary)
}

private func conversationCapabilityBadge(
  for integrationMode: DashboardConversationIntegrationMode
) -> some View {
  CapabilityBadge(
    label: integrationMode.rawValue.capitalized,
    icon: integrationMode == .direct ? "bolt.fill" : "eye",
    color: integrationMode == .direct ? .accent : .secondary
  )
}

private struct DashboardConversationActionsModifier: ViewModifier {
  let conversation: DashboardConversationRecord

  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry
  @State private var isEndingConversation = false

  func body(content: Content) -> some View {
    content
      .contextMenu {
        if conversation.canEnd {
          Button(role: .destructive) {
            Task { await endConversation() }
          } label: {
            Label("End Session", systemImage: "stop.circle")
          }
        }
      }
      .modifier(DashboardConversationSwipeActions(
        conversation: conversation,
        isEndingConversation: isEndingConversation,
        endConversation: endConversation
      ))
  }

  private func endConversation() async {
    guard !isEndingConversation else { return }
    isEndingConversation = true
    defer { isEndingConversation = false }

    do {
      let store = runtimeRegistry.sessionStore(
        for: conversation.sessionRef.endpointId,
        fallback: runtimeRegistry.activeSessionStore
      )
      try await store.endSession(conversation.sessionId)
      await runtimeRegistry.refreshDashboardConversations()
    } catch {
      return
    }
  }
}

private struct DashboardConversationSwipeActions: ViewModifier {
  let conversation: DashboardConversationRecord
  let isEndingConversation: Bool
  let endConversation: () async -> Void

  func body(content: Content) -> some View {
    #if os(iOS)
      content.swipeActions(edge: .trailing, allowsFullSwipe: false) {
        if conversation.canEnd {
          Button(role: .destructive) {
            Task { await endConversation() }
          } label: {
            Label(
              isEndingConversation ? "Ending" : "End",
              systemImage: isEndingConversation ? "stop.circle.fill" : "stop.circle"
            )
          }
          .tint(.red)
          .disabled(isEndingConversation)
        }
      }
    #else
      content
    #endif
  }
}

// MARK: - Utilities

/// Format a tool call into a human-readable description for dashboard previews.
/// Extracts the most meaningful parameter from known tools instead of dumping raw JSON.
private func formatToolContext(toolName: String, input: String?) -> String {
  guard let input, !input.isEmpty,
        let data = input.data(using: .utf8),
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  else {
    return "Wants to run \(toolName)"
  }

  switch toolName {
    case "Bash":
      if let command = json["command"] as? String {
        return command
      }
    case "Edit":
      if let path = json["file_path"] as? String {
        return "Edit \(URL(fileURLWithPath: path).lastPathComponent)"
      }
    case "Write":
      if let path = json["file_path"] as? String {
        return "Write \(URL(fileURLWithPath: path).lastPathComponent)"
      }
    case "Read":
      if let path = json["file_path"] as? String {
        return "Read \(URL(fileURLWithPath: path).lastPathComponent)"
      }
    case "Grep":
      if let pattern = json["pattern"] as? String {
        return "Search for \"\(pattern)\""
      }
    case "Glob":
      if let pattern = json["pattern"] as? String {
        return "Find files matching \(pattern)"
      }
    default:
      break
  }

  return "Wants to run \(toolName)"
}

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
    if interval < 3_600 { return "\(Int(interval / 60))m" }
    if interval < 86_400 { return "\(Int(interval / 3_600))h" }
    return "\(Int(interval / 86_400))d"
  }
}
