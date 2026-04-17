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

  // MARK: - Project List

  private var projectList: some View {
    VStack(alignment: .leading, spacing: 0) {
      ProjectNavigatorHeaderRow(
        groupCount: groups.count,
        hasCustomOrder: !projectOrder.isEmpty,
        onResetOrder: {
          withAnimation(Motion.standard) {
            projectOrder = []
          }
        }
      )

      ScrollView {
        LazyVStack(spacing: Spacing.xs) {
          ProjectNavigatorAllProjectsRow(
            isActive: projectFilter == nil,
            totalConversationCount: totalConversationCount,
            totalAttention: totalAttention,
            totalWorking: totalWorking,
            totalReady: totalReady,
            onSelect: { projectFilter = nil }
          )

          ProjectNavigatorFilterSection(
            totalCount: totalCount,
            counts: counts,
            directCount: directCount,
            workbenchFilter: $workbenchFilter,
            sort: $sort,
            providerFilter: $providerFilter,
            sortOptions: sortOptions
          )

          ForEach(groups) { group in
            ProjectNavigatorProjectRow(
              group: group,
              hasMultipleEndpoints: hasMultipleEndpoints,
              isActive: projectFilter == group.path,
              onToggle: {
                projectFilter = projectFilter == group.path ? nil : group.path
              }
            )
              .draggable(group.path) {
                Text(group.name)
                  .font(.system(size: TypeScale.caption, weight: .semibold))
                  .foregroundStyle(Color.textPrimary)
                  .padding(.horizontal, Spacing.sm)
                  .padding(.vertical, Spacing.xs)
                  .background(
                    Color.backgroundTertiary,
                    in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                  )
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
