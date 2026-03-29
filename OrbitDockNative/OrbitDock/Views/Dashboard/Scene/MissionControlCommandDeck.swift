import SwiftUI

struct MissionControlCommandDeck: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry

  let groups: [ConversationProjectGroup]
  let hasMultipleEndpoints: Bool
  @Binding var projectFilter: String?
  let selectedIndex: Int

  private var layoutMode: DashboardLayoutMode {
    DashboardLayoutMode.current(horizontalSizeClass: horizontalSizeClass)
  }

  private var selectedConversationID: String? {
    let conversations = groups.flatMap(\.sortedConversations)
    guard selectedIndex >= 0, selectedIndex < conversations.count else { return nil }
    return conversations[selectedIndex].id
  }

  var body: some View {
    if groups.isEmpty {
      emptyState
    } else {
      conversationFeed
    }
  }

  private var conversationFeed: some View {
    VStack(alignment: .leading, spacing: Spacing.xxl) {
      ForEach(groups) { group in
        ConversationProjectSection(
          group: group,
          showEndpointName: hasMultipleEndpoints,
          selectedConversationID: selectedConversationID,
          projectFilter: $projectFilter,
          layoutMode: layoutMode
        )
      }
    }
  }

  private var emptyState: some View {
    let emptyState = emptyStateCopy

    return VStack(alignment: .leading, spacing: Spacing.sm) {
      Text(emptyState.title)
        .font(.system(size: TypeScale.large, weight: .bold, design: .rounded))
        .foregroundStyle(Color.textPrimary)

      Text(emptyState.message)
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

  private var emptyStateCopy: (title: String, message: String) {
    let statuses = runtimeRegistry.runtimes
      .filter(\.endpoint.isEnabled)
      .map { runtimeRegistry.displayConnectionStatus(for: $0.endpoint.id) }

    if let message = statuses.compactMap(\.failureMessage).first(where: \.isCompatibilityGuidance) {
      return (
        "Server upgrade required",
        "\(message) Open Server Settings to reconnect to a newer OrbitDock server."
      )
    }

    if statuses.contains(where: \.isConnectingLike) {
      return (
        "Connecting to server",
        "OrbitDock is waiting for a compatible dashboard snapshot before showing sessions."
      )
    }

    if statuses.contains(where: \.isUnavailable) {
      return (
        "Server unavailable",
        "OrbitDock couldn't load session data from the configured server. Check Server Settings, then try reconnecting."
      )
    }

    return (
      "All clear",
      "No active conversations in this view. Start a session or adjust your filters."
    )
  }

}

private extension ConnectionStatus {
  var failureMessage: String? {
    guard case let .failed(message) = self else { return nil }
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  var isConnectingLike: Bool {
    switch self {
      case .connecting:
        true
      default:
        false
    }
  }

  var isUnavailable: Bool {
    switch self {
      case .disconnected, .failed:
        true
      case .connecting, .connected:
        false
    }
  }
}

private extension String {
  var isCompatibilityGuidance: Bool {
    let normalized = lowercased()
    return normalized.contains("compatible")
      || normalized.contains("compatibility")
      || normalized.contains("upgrade")
      || normalized.contains("too old")
  }
}

private struct ConversationProjectSection: View {
  let group: ConversationProjectGroup
  let showEndpointName: Bool
  let selectedConversationID: String?
  @Binding var projectFilter: String?
  let layoutMode: DashboardLayoutMode

  @State private var isExpanded = false

  private let sessionCap = 4

  private var isFocused: Bool {
    projectFilter == group.path
  }

  /// When a specific project is filtered, show all sessions (no cap)
  private var shouldCap: Bool {
    projectFilter == nil
  }

  private var visibleConversations: [DashboardConversationRecord] {
    let sorted = group.sortedConversations
    if !shouldCap || isExpanded || sorted.count <= sessionCap {
      return sorted
    }
    return Array(sorted.prefix(sessionCap))
  }

  private var overflowCount: Int {
    guard shouldCap else { return 0 }
    return max(0, group.sortedConversations.count - sessionCap)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      sectionHeader

      VStack(spacing: Spacing.sm) {
        ForEach(Array(visibleConversations.enumerated()), id: \.element.id) { _, conversation in
          conversationView(for: conversation)
        }
      }

      disclosureButton
    }
    .onChange(of: selectedConversationID) { _, newID in
      guard let newID, shouldCap, !isExpanded else { return }
      let hidden = Set(group.sortedConversations.dropFirst(sessionCap).map(\.id))
      if hidden.contains(newID) {
        withAnimation(Motion.standard) {
          isExpanded = true
        }
      }
    }
  }

  @ViewBuilder
  private var disclosureButton: some View {
    if overflowCount > 0 {
      if isExpanded {
        Button {
          withAnimation(Motion.standard) {
            isExpanded = false
          }
        } label: {
          HStack(spacing: Spacing.sm_) {
            Image(systemName: "chevron.up")
              .font(.system(size: IconScale.sm, weight: .semibold))
            Text("Show less")
              .font(.system(size: TypeScale.caption, weight: .semibold))
          }
          .foregroundStyle(Color.textTertiary)
          .padding(.horizontal, Spacing.lg)
          .padding(.vertical, Spacing.sm)
        }
        .buttonStyle(.plain)
      } else {
        Button {
          withAnimation(Motion.standard) {
            isExpanded = true
          }
        } label: {
          HStack(spacing: Spacing.sm_) {
            Image(systemName: "chevron.down")
              .font(.system(size: IconScale.sm, weight: .semibold))
            Text("Show \(overflowCount) more")
              .font(.system(size: TypeScale.caption, weight: .semibold))
          }
          .foregroundStyle(Color.accent)
          .padding(.horizontal, Spacing.lg)
          .padding(.vertical, Spacing.sm)
        }
        .buttonStyle(.plain)
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
          layoutMode: layoutMode
        )
        .equatable()
        .id(DashboardScrollIDs.session(conversation.id))

      case .working:
        ActivityConversationCard(
          conversation: conversation,
          isSelected: isSelected,
          showEndpointName: showEndpointName,
          layoutMode: layoutMode
        )
        .equatable()
        .id(DashboardScrollIDs.session(conversation.id))

      case .reply, .ended:
        CompactConversationRow(
          conversation: conversation,
          isSelected: isSelected,
          showEndpointName: showEndpointName,
          layoutMode: layoutMode
        )
        .equatable()
        .id(DashboardScrollIDs.session(conversation.id))
    }
  }

  // MARK: Section Header — sector label with signal dot + station callsign

  private enum SectionTier {
    case hot // attentionCount > 0
    case active // workingCount > 0
    case idle // only docked/ended
  }

  private var sectionTier: SectionTier {
    if group.attentionCount > 0 { return .hot }
    if group.workingCount > 0 { return .active }
    return .idle
  }

  private var sectionHeader: some View {
    let tier = sectionTier

    return HStack(alignment: .center, spacing: Spacing.sm_) {
      // Signal dot — size and glow scale with urgency
      Circle()
        .fill(group.signalColor)
        .frame(width: dotSize(tier), height: dotSize(tier))
        .shadow(
          color: tier == .idle
            ? Color.clear
            : group.signalColor.opacity(tier == .hot ? 0.6 : 0.4),
          radius: tier == .hot ? 6 : 4,
          y: 0
        )

      Text(group.name.uppercased())
        .font(.system(size: headerFontSize(tier), weight: headerFontWeight(tier)))
        .foregroundStyle(headerColor(tier))
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

      // Scanline divider — tinted for hot sections
      Rectangle()
        .fill(
          LinearGradient(
            colors: scanlineColors(tier),
            startPoint: .leading,
            endPoint: .trailing
          )
        )
        .frame(height: 0.5)

      focusButton
    }
  }

  private func dotSize(_ tier: SectionTier) -> CGFloat {
    switch tier {
      case .hot: 8
      case .active: 6
      case .idle: 5
    }
  }

  private func headerFontSize(_ tier: SectionTier) -> CGFloat {
    switch tier {
      case .hot: TypeScale.meta
      case .active: TypeScale.caption
      case .idle: TypeScale.caption
    }
  }

  private func headerFontWeight(_ tier: SectionTier) -> Font.Weight {
    switch tier {
      case .hot: .heavy
      case .active: .bold
      case .idle: .semibold
    }
  }

  private func headerColor(_ tier: SectionTier) -> Color {
    switch tier {
      case .hot: .textSecondary
      case .active: .textTertiary
      case .idle: .textQuaternary
    }
  }

  private func scanlineColors(_ tier: SectionTier) -> [Color] {
    switch tier {
      case .hot:
        [group.signalColor.opacity(0.3), group.signalColor.opacity(0.05)]
      case .active:
        [Color.surfaceBorder, Color.surfaceBorder.opacity(0.3)]
      case .idle:
        [Color.surfaceBorder.opacity(0.6), Color.surfaceBorder.opacity(0.15)]
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
      projectFilter = isFocused ? nil : group.path
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

private struct CompactConversationRow: View, Equatable {
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
    // Unread rows get a barely-visible ambient glow tint
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

      diffLabel(for: conversation)
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

// MARK: - Tier 2: Activity Card (Working)

private struct ActivityConversationCard: View, Equatable {
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
        Text(conversation.activitySummaryText)
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

  private func openConversation() {
    router.selectSession(conversation.sessionRef, source: .dashboardStream)
  }

  static func == (lhs: ActivityConversationCard, rhs: ActivityConversationCard) -> Bool {
    lhs.conversation == rhs.conversation
      && lhs.isSelected == rhs.isSelected
      && lhs.showEndpointName == rhs.showEndpointName
      && lhs.layoutMode == rhs.layoutMode
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

private struct AlertConversationCard: View, Equatable {
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
        Text(conversation.alertContextText)
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

  private func openConversation() {
    router.selectSession(conversation.sessionRef, source: .dashboardStream)
  }

  static func == (lhs: AlertConversationCard, rhs: AlertConversationCard) -> Bool {
    lhs.conversation == rhs.conversation
      && lhs.isSelected == rhs.isSelected
      && lhs.showEndpointName == rhs.showEndpointName
      && lhs.layoutMode == rhs.layoutMode
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

private enum RelativeClock {
  static func shortLabel(for date: Date, now: Date = .now) -> String {
    let interval = max(0, now.timeIntervalSince(date))
    if interval < 60 { return "now" }
    if interval < 3_600 { return "\(Int(interval / 60))m" }
    if interval < 86_400 { return "\(Int(interval / 3_600))h" }
    return "\(Int(interval / 86_400))d"
  }
}
