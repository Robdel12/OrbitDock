import SwiftUI

struct ConversationProjectSection: View {
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
      let hiddenConversationIDs = Set(group.sortedConversations.dropFirst(sessionCap).map(\.id))
      if hiddenConversationIDs.contains(newID) {
        withAnimation(Motion.standard) {
          isExpanded = true
        }
      }
    }
  }

  @ViewBuilder
  private var disclosureButton: some View {
    if overflowCount > 0 {
      Button {
        withAnimation(Motion.standard) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: Spacing.sm_) {
          Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.system(size: IconScale.sm, weight: .semibold))
          Text(isExpanded ? "Show less" : "Show \(overflowCount) more")
            .font(.system(size: TypeScale.caption, weight: .semibold))
        }
        .foregroundStyle(isExpanded ? Color.textTertiary : Color.accent)
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
      }
      .buttonStyle(.plain)
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

  private var sectionTier: ConversationProjectSectionTier {
    if group.attentionCount > 0 { return .hot }
    if group.workingCount > 0 { return .active }
    return .idle
  }

  private var sectionHeader: some View {
    let tier = sectionTier

    return HStack(alignment: .center, spacing: Spacing.sm_) {
      Circle()
        .fill(group.signalColor)
        .frame(width: tier.dotSize, height: tier.dotSize)
        .shadow(
          color: tier.shadowColor(signalColor: group.signalColor),
          radius: tier.shadowRadius,
          y: 0
        )

      Text(group.name.uppercased())
        .font(.system(size: tier.headerFontSize, weight: tier.headerFontWeight))
        .foregroundStyle(tier.headerColor)
        .tracking(1.5)

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

      Rectangle()
        .fill(tier.scanlineColor(signalColor: group.signalColor))
        .frame(height: 0.5)

      Button(isFocused ? "Show all" : "Track") {
        projectFilter = isFocused ? nil : group.path
      }
      .buttonStyle(.plain)
      .font(.system(size: TypeScale.caption, weight: .semibold))
      .foregroundStyle(isFocused ? Color.textSecondary : Color.accent)
    }
  }

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

private enum ConversationProjectSectionTier {
  case hot
  case active
  case idle

  var dotSize: CGFloat {
    switch self {
      case .hot: 8
      case .active: 6
      case .idle: 5
    }
  }

  var shadowRadius: CGFloat {
    switch self {
      case .hot: 6
      case .active: 4
      case .idle: 0
    }
  }

  var headerFontSize: CGFloat {
    switch self {
      case .hot: TypeScale.meta
      case .active, .idle: TypeScale.caption
    }
  }

  var headerFontWeight: Font.Weight {
    switch self {
      case .hot: .heavy
      case .active: .bold
      case .idle: .semibold
    }
  }

  var headerColor: Color {
    switch self {
      case .hot: .textSecondary
      case .active: .textTertiary
      case .idle: .textQuaternary
    }
  }

  func shadowColor(signalColor: Color) -> Color {
    switch self {
      case .hot:
        signalColor.opacity(0.6)
      case .active:
        signalColor.opacity(0.4)
      case .idle:
        .clear
    }
  }

  func scanlineColor(signalColor: Color) -> Color {
    switch self {
      case .hot:
        signalColor.opacity(0.3)
      case .active:
        Color.surfaceBorder
      case .idle:
        Color.surfaceBorder.opacity(0.6)
    }
  }
}
