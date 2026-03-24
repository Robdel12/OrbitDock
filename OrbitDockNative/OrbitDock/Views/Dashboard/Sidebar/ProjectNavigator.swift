import SwiftUI

struct ProjectNavigator: View {
  let groups: [ConversationProjectGroup]
  let totalConversationCount: Int
  let hasMultipleEndpoints: Bool
  @Binding var projectFilter: String?
  @Binding var projectOrder: [String]
  let width: CGFloat

  // Filter/sort controls (absorbed from toolbar)
  let totalCount: Int
  let counts: DashboardTriageCounts
  let directCount: Int
  @Binding var workbenchFilter: ActiveSessionWorkbenchFilter
  @Binding var sort: ActiveSessionSort
  @Binding var providerFilter: ActiveSessionProviderFilter
  var sortOptions: [ActiveSessionSort] = [.recent, .status, .name]

  @State private var dragTargetGroupID: String?

  private var totalAttention: Int {
    groups.reduce(0) { $0 + $1.attentionCount }
  }

  private var totalWorking: Int {
    groups.reduce(0) { $0 + $1.workingCount }
  }

  private var totalReady: Int {
    groups.reduce(0) { $0 + $1.readyCount }
  }

  private var hasAnyFilters: Bool {
    workbenchFilter != .all || providerFilter != .all
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      projectList

      sectionDivider

      SidebarUsageSection()
    }
    .frame(width: width)
    .background(Color.backgroundSecondary.opacity(0.2))
  }

  private var sectionDivider: some View {
    Rectangle()
      .fill(Color.surfaceBorder.opacity(OpacityTier.subtle))
      .frame(height: 1)
      .padding(.horizontal, Spacing.md)
  }

  // MARK: - Filter Section (absorbed from toolbar)

  private var filterSection: some View {
    VStack(spacing: Spacing.sm) {
      // Filter chips
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: Spacing.xs) {
          sidebarFilterChip(target: .all, icon: nil, label: "All", count: totalCount, color: .textSecondary)

          if counts.attention > 0 || workbenchFilter == .attention {
            sidebarFilterChip(
              target: .attention,
              icon: "exclamationmark.circle.fill",
              label: "Attn",
              count: counts.attention,
              color: .statusPermission
            )
          }

          if counts.running > 0 || workbenchFilter == .running {
            sidebarFilterChip(
              target: .running,
              icon: "bolt.fill",
              label: "Running",
              count: counts.running,
              color: .statusWorking
            )
          }

          if counts.ready > 0 || workbenchFilter == .ready {
            sidebarFilterChip(target: .ready, icon: "bubble.left.fill", label: "Ready", count: counts.ready, color: .statusReply)
          }

          if directCount > 0 || workbenchFilter == .direct {
            sidebarFilterChip(
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

      // Sort + Provider row
      HStack(spacing: Spacing.xs) {
        sidebarSortMenu
        sidebarProviderMenu

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

  private func sidebarFilterChip(
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

  private var sidebarSortMenu: some View {
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

  private var sidebarProviderMenu: some View {
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

  // MARK: - Project List

  private var projectList: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: Spacing.sm_) {
        Text("PROJECTS")
          .font(.system(size: TypeScale.micro, weight: .heavy))
          .foregroundStyle(Color.textTertiary)
          .tracking(0.8)

        Text("\(groups.count)")
          .font(.system(size: TypeScale.micro, weight: .bold, design: .rounded))
          .foregroundStyle(Color.textQuaternary)
          .padding(.horizontal, 5)
          .padding(.vertical, 1)
          .background(Color.surfaceHover.opacity(0.5), in: Capsule())

        Spacer()

        if !projectOrder.isEmpty {
          Button {
            withAnimation(Motion.standard) {
              projectOrder = []
            }
          } label: {
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

      ScrollView {
        LazyVStack(spacing: Spacing.xs) {
          allProjectsRow

          filterSection

          ForEach(groups) { group in
            projectRow(group)
              .draggable(group.path) {
                // Drag preview — lightweight label
                Text(group.name)
                  .font(.system(size: TypeScale.caption, weight: .semibold))
                  .foregroundStyle(Color.textPrimary)
                  .padding(.horizontal, Spacing.sm)
                  .padding(.vertical, Spacing.xs)
                  .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
              }
              .dropDestination(for: String.self) { droppedPaths, _ in
                guard let sourcePath = droppedPaths.first else { return false }
                reorderProject(sourcePath: sourcePath, targetPath: group.path)
                return true
              } isTargeted: { isTargeted in
                withAnimation(Motion.snappy) {
                  dragTargetGroupID = isTargeted ? group.id : nil
                }
              }
              .overlay(alignment: .top) {
                if dragTargetGroupID == group.id {
                  Rectangle()
                    .fill(Color.accent)
                    .frame(height: 2)
                    .transition(.opacity)
                }
              }
          }
        }
        .padding(.horizontal, Spacing.sm_)
        .padding(.bottom, Spacing.md)
      }
    }
  }

  // MARK: - All Projects Row

  private var allProjectsRow: some View {
    let isActive = projectFilter == nil

    return VStack(spacing: 0) {
      Button {
        projectFilter = nil
      } label: {
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

      // Separator below "All Projects" to distinguish from individual projects
      Rectangle()
        .fill(Color.surfaceBorder.opacity(OpacityTier.subtle))
        .frame(height: 1)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.sm_)
    }
  }

  // MARK: - Project Row (Three Visual Tiers)

  private enum ProjectTier {
    case hot      // attentionCount > 0
    case active   // workingCount > 0
    case idle     // only docked/ended
  }

  private func projectTier(for group: ConversationProjectGroup) -> ProjectTier {
    if group.attentionCount > 0 { return .hot }
    if group.workingCount > 0 { return .active }
    return .idle
  }

  private func isStale(_ group: ConversationProjectGroup) -> Bool {
    guard let lastActivity = group.lastActivityAt else { return true }
    return Date.now.timeIntervalSince(lastActivity) > 43_200 // 12 hours
  }

  private func projectRow(_ group: ConversationProjectGroup) -> some View {
    let isActive = projectFilter == group.path
    let tier = projectTier(for: group)
    let stale = tier == .idle && isStale(group)

    return Button {
      projectFilter = (projectFilter == group.path) ? nil : group.path
    } label: {
      HStack(alignment: .top, spacing: Spacing.sm_) {
        // Signal dot — size and glow vary by tier
        Circle()
          .fill(group.signalColor)
          .frame(width: signalDotSize(tier), height: signalDotSize(tier))
          .shadow(
            color: tier == .idle
              ? Color.clear
              : group.signalColor.opacity(tier == .hot ? 0.6 : 0.4),
            radius: tier == .hot ? 6 : 3,
            y: 0
          )
          .padding(.top, 5)

        VStack(alignment: .leading, spacing: Spacing.xs) {
          // Project name + recency
          HStack(spacing: Spacing.sm_) {
            Text(group.name)
              .font(.system(size: TypeScale.body, weight: nameWeight(tier: tier, isActive: isActive)))
              .foregroundStyle(nameColor(tier: tier, isActive: isActive, stale: stale))
              .lineLimit(1)

            Spacer(minLength: 0)

            if let recency = recencyLabel(for: group.lastActivityAt) {
              Text(recency)
                .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
                .foregroundStyle(stale ? Color.textQuaternary.opacity(0.6) : Color.textQuaternary)
            }
          }

          // Status capsules — dimmed for idle
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
                  tint: stale ? .textQuaternary : .statusReply
                )
              }
            }
          }

          // Latest activity preview — only for hot and active tiers
          if tier != .idle, let preview = group.sortedConversations.first {
            Text(preview.compactPreviewText)
              .font(.system(size: TypeScale.caption, weight: .regular))
              .foregroundStyle(Color.textTertiary)
              .lineLimit(1)
          }

          // Endpoint badge
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
      .background(rowBackground(tier: tier, isActive: isActive, group: group))
      .overlay(alignment: .leading) {
        // Left accent border for hot projects
        if tier == .hot && !isActive {
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

  // MARK: - Tier Helpers

  private func signalDotSize(_ tier: ProjectTier) -> CGFloat {
    switch tier {
      case .hot: 8
      case .active: 7
      case .idle: 5
    }
  }

  private func nameWeight(tier: ProjectTier, isActive: Bool) -> Font.Weight {
    if isActive { return .bold }
    switch tier {
      case .hot: return .semibold
      case .active: return .medium
      case .idle: return .regular
    }
  }

  private func nameColor(tier: ProjectTier, isActive: Bool, stale: Bool) -> Color {
    if isActive { return .accent }
    switch tier {
      case .hot: return .textPrimary
      case .active: return .textPrimary
      case .idle: return stale ? .textTertiary : .textSecondary
    }
  }

  private func rowBackground(
    tier: ProjectTier,
    isActive: Bool,
    group: ConversationProjectGroup
  ) -> some View {
    RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
      .fill(rowFill(tier: tier, isActive: isActive, group: group))
  }

  private func rowFill(
    tier: ProjectTier,
    isActive: Bool,
    group: ConversationProjectGroup
  ) -> Color {
    if isActive { return .accent.opacity(0.10) }
    if tier == .hot { return group.signalColor.opacity(OpacityTier.tint) }
    return .clear
  }

  // MARK: - Shared

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

  private func recencyLabel(for date: Date?) -> String? {
    guard let date else { return nil }
    let interval = max(0, Date.now.timeIntervalSince(date))
    if interval < 60 { return "now" }
    if interval < 3_600 { return "\(Int(interval / 60))m" }
    if interval < 86_400 { return "\(Int(interval / 3_600))h" }
    return "\(Int(interval / 86_400))d"
  }

  // MARK: - Reorder

  private func reorderProject(sourcePath: String, targetPath: String) {
    guard sourcePath != targetPath else { return }

    // Initialize order from current groups if empty
    var order = projectOrder.isEmpty
      ? groups.map(\.path)
      : projectOrder

    // Ensure both paths are in the order array
    if !order.contains(sourcePath) { order.append(sourcePath) }
    if !order.contains(targetPath) { order.append(targetPath) }

    guard let sourceIndex = order.firstIndex(of: sourcePath),
          let targetIndex = order.firstIndex(of: targetPath)
    else { return }

    let item = order.remove(at: sourceIndex)
    order.insert(item, at: targetIndex)
    projectOrder = order
  }
}
