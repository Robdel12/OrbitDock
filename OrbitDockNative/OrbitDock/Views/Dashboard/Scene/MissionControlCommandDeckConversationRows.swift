import SwiftUI

struct CompactConversationRow: View, Equatable {
  @Environment(AppRouter.self) private var router

  let conversation: DashboardConversationRecord
  let isSelected: Bool
  let showEndpointName: Bool
  let layoutMode: DashboardLayoutMode

  @State private var isHovering = false

  private var hasUnread: Bool {
    conversation.unreadCount > 0
  }

  private var recencyLabel: String? {
    let date = conversation.lastActivityAt ?? conversation.startedAt
    guard let date else { return nil }
    return RelativeClock.shortLabel(for: date)
  }

  var body: some View {
    Button(action: openConversation) {
      VStack(alignment: .leading, spacing: 3) {
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

        HStack(alignment: .firstTextBaseline, spacing: 0) {
          Text(conversation.compactPreviewText)
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
    if hasUnread { return Color.accent.opacity(OpacityTier.tint) }
    return Color.clear
  }

  private var compactMetadata: some View {
    HStack(spacing: Spacing.sm_) {
      if showEndpointName, let name = conversation.endpointName {
        endpointTag(name)
      }

      if let branch = conversation.compactBranchLabel {
        Text(branch)
          .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
          .foregroundStyle(Color.textQuaternary)
      }

      if let model = conversation.modelDisplayLabel {
        Text(model)
          .font(.system(size: TypeScale.micro, weight: .medium))
          .foregroundStyle(Color.textQuaternary)
      }

      dashboardDiffLabel(for: conversation)
    }
  }

  private func openConversation() {
    router.selectSession(conversation.sessionRef, source: .dashboardStream)
  }

  static func == (lhs: CompactConversationRow, rhs: CompactConversationRow) -> Bool {
    lhs.conversation == rhs.conversation
      && lhs.isSelected == rhs.isSelected
      && lhs.showEndpointName == rhs.showEndpointName
      && lhs.layoutMode == rhs.layoutMode
  }
}

struct ActivityConversationCard: View, Equatable {
  @Environment(AppRouter.self) private var router

  let conversation: DashboardConversationRecord
  let isSelected: Bool
  let showEndpointName: Bool
  let layoutMode: DashboardLayoutMode

  @State private var isHovering = false

  private var recencyLabel: String {
    let date = conversation.lastActivityAt ?? conversation.startedAt
    guard let date else { return "now" }
    return RelativeClock.shortLabel(for: date)
  }

  var body: some View {
    Button(action: openConversation) {
      VStack(alignment: .leading, spacing: Spacing.sm_) {
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

        Text(conversation.activitySummaryText)
          .font(.system(size: TypeScale.body, weight: .regular))
          .foregroundStyle(Color.textSecondary)
          .lineLimit(1)

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

          if let branch = conversation.expandedBranchLabel {
            Text(branch)
              .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
              .foregroundStyle(Color.textQuaternary)
          }

          if let model = conversation.modelDisplayLabel, !layoutMode.isPhoneCompact {
            Text(model)
              .font(.system(size: TypeScale.micro, weight: .medium))
              .foregroundStyle(Color.textQuaternary)
          }

          dashboardDiffLabel(for: conversation)

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

  private func openConversation() {
    router.selectSession(conversation.sessionRef, source: .dashboardStream)
  }

  private var cardBackground: some View {
    ZStack {
      RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
        .fill(Color.backgroundTertiary)

      RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
        .fill(Color.statusWorking.opacity(isHovering ? 0.06 : 0.03))

      RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
        .stroke(
          Color.statusWorking.opacity(isHovering || isSelected ? 0.30 : 0.18),
          lineWidth: isSelected ? 1.4 : 1
        )
    }
    .shadow(color: Color.statusWorking.opacity(0.14), radius: 10, y: 0)
    .shadow(color: Color.statusWorking.opacity(0.08), radius: 3, y: 0)
  }

  static func == (lhs: ActivityConversationCard, rhs: ActivityConversationCard) -> Bool {
    lhs.conversation == rhs.conversation
      && lhs.isSelected == rhs.isSelected
      && lhs.showEndpointName == rhs.showEndpointName
      && lhs.layoutMode == rhs.layoutMode
  }
}

struct AlertConversationCard: View, Equatable {
  @Environment(AppRouter.self) private var router

  let conversation: DashboardConversationRecord
  let isSelected: Bool
  let showEndpointName: Bool
  let layoutMode: DashboardLayoutMode

  @State private var isHovering = false

  private var statusColor: Color {
    conversation.displayStatus.color
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
    Button(action: openConversation) {
      VStack(alignment: .leading, spacing: Spacing.md_) {
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

        Text(conversation.alertContextText)
          .font(.system(size: TypeScale.body, weight: .medium))
          .foregroundStyle(Color.textSecondary)
          .lineLimit(3)
          .frame(maxWidth: .infinity, alignment: .leading)

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

          if let branch = conversation.expandedBranchLabel {
            Text(branch)
              .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
              .foregroundStyle(Color.textQuaternary)
          }

          if let model = conversation.modelDisplayLabel, !layoutMode.isPhoneCompact {
            Text(model)
              .font(.system(size: TypeScale.micro, weight: .medium))
              .foregroundStyle(Color.textQuaternary)
          }

          dashboardDiffLabel(for: conversation)

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

  private func openConversation() {
    router.selectSession(conversation.sessionRef, source: .dashboardStream)
  }

  private var cardBackground: some View {
    ZStack {
      RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
        .fill(Color.backgroundTertiary)

      RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
        .fill(statusColor.opacity(isHovering ? 0.08 : 0.04))

      RoundedRectangle(cornerRadius: Radius.xl, style: .continuous)
        .stroke(
          statusColor.opacity(isHovering || isSelected ? 0.40 : 0.25),
          lineWidth: isSelected ? 1.6 : 1.2
        )
    }
    .shadow(color: statusColor.opacity(0.22), radius: 16, y: 0)
    .shadow(color: statusColor.opacity(0.12), radius: 5, y: 0)
  }

  static func == (lhs: AlertConversationCard, rhs: AlertConversationCard) -> Bool {
    lhs.conversation == rhs.conversation
      && lhs.isSelected == rhs.isSelected
      && lhs.showEndpointName == rhs.showEndpointName
      && lhs.layoutMode == rhs.layoutMode
  }
}

@ViewBuilder
private func dashboardDiffLabel(for conversation: DashboardConversationRecord) -> some View {
  if conversation.hasTurnDiff, let diff = conversation.diffPreview,
     diff.fileCount > 0 || diff.additions > 0 || diff.deletions > 0
  {
    HStack(spacing: Spacing.gap) {
      Text("+\(diff.additions)")
        .foregroundStyle(Color.diffAddedAccent.opacity(0.7))
      Text("−\(diff.deletions)")
        .foregroundStyle(Color.diffRemovedAccent.opacity(0.7))
      if diff.fileCount > 0 {
        Text("\(diff.fileCount) \(diff.fileCount == 1 ? "file" : "files")")
          .foregroundStyle(Color.textQuaternary)
      }
    }
    .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
  }
}

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

  @Environment(DashboardDataService.self) private var dashboardDataService
  @Environment(\.rootSessionActions) private var rootSessionActions
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
      try await rootSessionActions.endSession(conversation.sessionRef)
      await dashboardDataService.refreshNow()
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

private enum RelativeClock {
  static func shortLabel(for date: Date, now: Date = .now) -> String {
    let interval = max(0, now.timeIntervalSince(date))
    if interval < 60 { return "now" }
    if interval < 3_600 { return "\(Int(interval / 60))m" }
    if interval < 86_400 { return "\(Int(interval / 3_600))h" }
    return "\(Int(interval / 86_400))d"
  }
}
