import SwiftUI

struct ProjectNavigatorHeaderRow: View {
  let groupCount: Int
  let hasCustomOrder: Bool
  let onResetOrder: () -> Void

  var body: some View {
    HStack(spacing: Spacing.sm_) {
      Text("PROJECTS")
        .font(.system(size: TypeScale.micro, weight: .heavy))
        .foregroundStyle(Color.textTertiary)
        .tracking(0.8)

      Text("\(groupCount)")
        .font(.system(size: TypeScale.micro, weight: .bold, design: .rounded))
        .foregroundStyle(Color.textQuaternary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Color.surfaceHover.opacity(0.5), in: Capsule())

      Spacer()

      if hasCustomOrder {
        Button(action: onResetOrder) {
          Image(systemName: "arrow.up.arrow.down")
            .font(.system(size: IconScale.sm, weight: .medium))
            .foregroundStyle(Color.textQuaternary)
        }
        .buttonStyle(.plain)
        .help("Reset to alphabetical order")
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.top, Spacing.md)
    .padding(.bottom, Spacing.sm)
  }
}

struct ProjectNavigatorFilterSection: View {
  let totalCount: Int
  let counts: DashboardTriageCounts
  let directCount: Int
  @Binding var workbenchFilter: ActiveSessionWorkbenchFilter
  @Binding var sort: ActiveSessionSort
  @Binding var providerFilter: ActiveSessionProviderFilter
  let sortOptions: [ActiveSessionSort]

  private var hasAnyFilters: Bool {
    workbenchFilter != .all || providerFilter != .all
  }

  var body: some View {
    VStack(spacing: Spacing.sm) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: Spacing.xs) {
          filterChip(target: .all, icon: nil, label: "All", count: totalCount, color: .textSecondary)

          if counts.attention > 0 || workbenchFilter == .attention {
            filterChip(
              target: .attention,
              icon: "exclamationmark.circle.fill",
              label: "Attn",
              count: counts.attention,
              color: .statusPermission
            )
          }

          if counts.running > 0 || workbenchFilter == .running {
            filterChip(
              target: .running,
              icon: "bolt.fill",
              label: "Running",
              count: counts.running,
              color: .statusWorking
            )
          }

          if counts.ready > 0 || workbenchFilter == .ready {
            filterChip(
              target: .ready,
              icon: "bubble.left.fill",
              label: "Ready",
              count: counts.ready,
              color: .statusReply
            )
          }

          if directCount > 0 || workbenchFilter == .direct {
            filterChip(
              target: .direct,
              icon: "chevron.left.forwardslash.chevron.right",
              label: "Direct",
              count: directCount,
              color: .providerCodex
            )
          }
        }
        .padding(.vertical, Spacing.xxs)
      }

      HStack(spacing: Spacing.xs) {
        sortMenu
        providerMenu

        Spacer(minLength: 0)

        if hasAnyFilters {
          Button {
            workbenchFilter = .all
            providerFilter = .all
          } label: {
            Text("Clear")
              .font(.system(size: TypeScale.mini, weight: .semibold))
              .foregroundStyle(Color.textTertiary)
              .padding(.horizontal, Spacing.sm)
              .padding(.vertical, Spacing.xs)
              .background(Color.textTertiary.opacity(0.10), in: Capsule())
          }
          .buttonStyle(.plain)
        }
      }
    }
    .padding(.horizontal, Spacing.sm)
    .padding(.vertical, Spacing.sm)
    .background(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .fill(Color.backgroundSecondary.opacity(0.34))
    )
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .strokeBorder(Color.surfaceBorder.opacity(OpacityTier.subtle), lineWidth: 1)
    )
  }

  private func filterChip(
    target: ActiveSessionWorkbenchFilter,
    icon: String?,
    label: String,
    count: Int,
    color: Color
  ) -> some View {
    let isActive = workbenchFilter == target

    return Button {
      workbenchFilter = isActive ? .all : target
    } label: {
      HStack(spacing: Spacing.xs) {
        if let icon {
          Image(systemName: icon)
            .font(.system(size: TypeScale.mini, weight: .bold))
            .foregroundStyle(isActive ? color : color.opacity(0.6))
        }

        Text("\(count)")
          .font(.system(size: TypeScale.caption, weight: .bold, design: .monospaced))
          .foregroundStyle(isActive ? color : Color.textSecondary)

        Text(label)
          .font(.system(size: TypeScale.micro, weight: .semibold))
      }
      .foregroundStyle(isActive ? color : Color.textTertiary)
      .padding(.horizontal, Spacing.sm_)
      .padding(.vertical, Spacing.xs)
      .background(
        Capsule()
          .fill((isActive ? color : Color.surfaceHover).opacity(isActive ? 0.14 : 0.22))
          .overlay(
            Capsule()
              .stroke(color.opacity(isActive ? 0.24 : 0.0), lineWidth: 1)
          )
      )
    }
    .buttonStyle(.plain)
  }

  private var sortMenu: some View {
    Menu {
      ForEach(sortOptions) { option in
        Button {
          sort = option
        } label: {
          HStack {
            Text(option.label)
            if sort == option {
              Image(systemName: "checkmark")
            }
          }
        }
      }
    } label: {
      HStack(spacing: Spacing.xs) {
        Image(systemName: sort.icon)
          .font(.system(size: TypeScale.micro, weight: .medium))
        Text(sort.label)
          .font(.system(size: TypeScale.micro, weight: .semibold))
      }
      .foregroundStyle(Color.textTertiary)
      .padding(.horizontal, Spacing.sm_)
      .padding(.vertical, Spacing.xs)
      .background(
        Capsule(style: .continuous)
          .fill(Color.backgroundPrimary.opacity(0.34))
      )
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }

  private var providerMenu: some View {
    Menu {
      ForEach(ActiveSessionProviderFilter.allCases) { option in
        Button {
          providerFilter = option
        } label: {
          HStack {
            Text(option.label)
            if providerFilter == option {
              Image(systemName: "checkmark")
            }
          }
        }
      }
    } label: {
      HStack(spacing: Spacing.xs) {
        Image(systemName: "line.3.horizontal.decrease.circle")
          .font(.system(size: TypeScale.micro, weight: .medium))
        Text(providerFilter == .all ? "Provider" : providerFilter.label)
          .font(.system(size: TypeScale.micro, weight: .semibold))
      }
      .foregroundStyle(providerFilter != .all ? Color.accent : Color.textTertiary)
      .padding(.horizontal, Spacing.sm_)
      .padding(.vertical, Spacing.xs)
      .background(
        Capsule(style: .continuous)
          .fill(Color.backgroundPrimary.opacity(0.34))
      )
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
  }
}

struct ProjectNavigatorAllProjectsRow: View {
  let isActive: Bool
  let totalConversationCount: Int
  let totalAttention: Int
  let totalWorking: Int
  let totalReady: Int
  let onSelect: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      Button(action: onSelect) {
        VStack(alignment: .leading, spacing: Spacing.xs) {
          HStack(spacing: Spacing.sm_) {
            Text("All Projects")
              .font(.system(size: TypeScale.subhead, weight: isActive ? .bold : .semibold))
              .foregroundStyle(isActive ? Color.accent : Color.textPrimary)
              .lineLimit(1)

            Spacer(minLength: 0)

            Text("\(totalConversationCount)")
              .font(.system(size: TypeScale.caption, weight: .bold, design: .rounded))
              .foregroundStyle(Color.textQuaternary)
          }

          if totalAttention > 0 || totalWorking > 0 || totalReady > 0 {
            HStack(spacing: Spacing.xs) {
              if totalAttention > 0 {
                statusPill("\(totalAttention) blocked", tint: .statusPermission)
              }
              if totalWorking > 0 {
                statusPill("\(totalWorking) in orbit", tint: .statusWorking)
              }
              if totalReady > 0 {
                statusPill("\(totalReady) docked", tint: .statusReply)
              }
            }
          }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.sm)
        .background(
          RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .fill(isActive ? Color.accent.opacity(0.10) : Color.surfaceHover.opacity(0.3))
        )
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      Rectangle()
        .fill(Color.surfaceBorder.opacity(OpacityTier.subtle))
        .frame(height: 1)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.sm_)
    }
  }
}

struct ProjectNavigatorProjectRow: View {
  let group: ConversationProjectGroup
  let hasMultipleEndpoints: Bool
  let isActive: Bool
  let onToggle: () -> Void

  private var tier: ProjectNavigatorProjectTier {
    if group.attentionCount > 0 { return .hot }
    if group.workingCount > 0 { return .active }
    return .idle
  }

  private var isStale: Bool {
    guard let lastActivity = group.lastActivityAt else { return true }
    return Date.now.timeIntervalSince(lastActivity) > 43_200
  }

  private var rowFill: Color {
    if isActive { return .accent.opacity(0.10) }
    if tier == .hot { return group.signalColor.opacity(OpacityTier.tint) }
    return .clear
  }

  var body: some View {
    Button(action: onToggle) {
      HStack(alignment: .top, spacing: Spacing.sm_) {
        Circle()
          .fill(group.signalColor)
          .frame(width: tier.signalDotSize, height: tier.signalDotSize)
          .shadow(
            color: tier.shadowColor(signalColor: group.signalColor),
            radius: tier.shadowRadius,
            y: 0
          )
          .padding(.top, 5)

        VStack(alignment: .leading, spacing: Spacing.xs) {
          HStack(spacing: Spacing.sm_) {
            Text(group.name)
              .font(.system(size: TypeScale.body, weight: tier.nameWeight(isActive: isActive)))
              .foregroundStyle(tier.nameColor(isActive: isActive, isStale: isStale))
              .lineLimit(1)

            Spacer(minLength: 0)

            if let recency = recencyLabel(for: group.lastActivityAt) {
              Text(recency)
                .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
                .foregroundStyle(isStale ? Color.textQuaternary.opacity(0.6) : Color.textQuaternary)
            }
          }

          if group.attentionCount > 0 || group.workingCount > 0 || group.readyCount > 0 {
            HStack(spacing: Spacing.xs) {
              if group.attentionCount > 0 {
                statusPill("\(group.attentionCount) blocked", tint: .statusPermission)
              }
              if group.workingCount > 0 {
                statusPill("\(group.workingCount) in orbit", tint: .statusWorking)
              }
              if group.readyCount > 0 {
                statusPill(
                  "\(group.readyCount) docked",
                  tint: isStale ? .textQuaternary : .statusReply
                )
              }
            }
          }

          if tier != .idle, let preview = group.sortedConversations.first {
            Text(preview.compactPreviewText)
              .font(.system(size: TypeScale.caption, weight: .regular))
              .foregroundStyle(Color.textTertiary)
              .lineLimit(1)
          }

          if hasMultipleEndpoints, let endpointName = group.endpointName {
            HStack(spacing: 2) {
              Image(systemName: "server.rack")
                .font(.system(size: IconScale.xs, weight: .medium))
              Text(endpointName)
                .font(.system(size: TypeScale.micro, weight: .medium))
            }
            .foregroundStyle(Color.textQuaternary)
          }
        }
      }
      .padding(.horizontal, Spacing.sm)
      .padding(.vertical, Spacing.sm)
      .background(
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          .fill(rowFill)
      )
      .overlay(alignment: .leading) {
        if tier == .hot, !isActive {
          RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(group.signalColor)
            .frame(width: 2)
            .padding(.vertical, Spacing.sm_)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func recencyLabel(for date: Date?) -> String? {
    guard let date else { return nil }
    let interval = max(0, Date.now.timeIntervalSince(date))
    if interval < 60 { return "now" }
    if interval < 3_600 { return "\(Int(interval / 60))m" }
    if interval < 86_400 { return "\(Int(interval / 3_600))h" }
    return "\(Int(interval / 86_400))d"
  }
}

private enum ProjectNavigatorProjectTier {
  case hot
  case active
  case idle

  var signalDotSize: CGFloat {
    switch self {
      case .hot: 8
      case .active: 7
      case .idle: 5
    }
  }

  var shadowRadius: CGFloat {
    switch self {
      case .hot: 6
      case .active: 3
      case .idle: 0
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

  func nameWeight(isActive: Bool) -> Font.Weight {
    if isActive { return .bold }
    switch self {
      case .hot: return .semibold
      case .active: return .medium
      case .idle: return .regular
    }
  }

  func nameColor(isActive: Bool, isStale: Bool) -> Color {
    if isActive { return .accent }
    switch self {
      case .hot, .active:
        return Color.textPrimary
      case .idle:
        return isStale ? Color.textTertiary : Color.textSecondary
    }
  }
}

private func statusPill(_ label: String, tint: Color) -> some View {
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
