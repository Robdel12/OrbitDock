//
//  DashboardView.swift
//  OrbitDock
//
//  Home view — switches between Mission Control (active agents) and Library
//  (project archive) via tab switcher in the status bar.
//
//  Connection health is handled inline in DashboardStatusBar's server button.
//

import SwiftUI

struct DashboardView: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(AppRouter.self) private var router
  @Environment(AppStore.self) private var appStore
  @State private var viewModel = DashboardViewModel()

  let isInitialLoading: Bool
  let isRefreshingCachedSessions: Bool

  @State private var sidebarDragWidth: CGFloat?
  @State private var sidebarDragStartWidth: CGFloat?
  @FocusState private var isDashboardFocused: Bool
  @AppStorage("dashboard.missionControl.sidebarWidth") private var persistedSidebarWidth: Double = 244

  private var isMissionControlVisible: Bool {
    guard case .dashboard(.missionControl) = router.route else { return false }
    return true
  }

  private var isDashboardInteractionEnabled: Bool {
    isMissionControlVisible && !router.showQuickSwitcher
  }

  private var dashboardScrollAnchorBinding: Binding<String?> {
    Binding(
      get: { viewModel.dashboardScrollAnchorID },
      set: { viewModel.dashboardScrollAnchorID = $0 }
    )
  }

  var body: some View {
    @Bindable var viewModel = viewModel

    GeometryReader { proxy in
      let containerWidth = proxy.size.width
      let layoutMode = DashboardLayoutMode.current(
        horizontalSizeClass: horizontalSizeClass,
        containerWidth: containerWidth
      )

      VStack(spacing: 0) {
        DashboardStatusBar(
          sessions: viewModel.rootSessions,
          isInitialLoading: isInitialLoading,
          isRefreshingCachedSessions: isRefreshingCachedSessions
        )

        switch router.dashboardTab {
          case .missionControl:
            missionControlLayout(
              layoutMode: layoutMode,
              containerWidth: containerWidth
            )
          case .missions:
            missionsTab
          case .library:
            LibraryView(
              sessions: viewModel.librarySessions,
              containerWidth: containerWidth
            )
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Color.backgroundPrimary)
    }
    #if os(iOS)
    .navigationTitle(router.dashboardTab.navigationTitle)
    .navigationBarHidden(true)
    #endif
  }

  // MARK: - Missions Tab

  @ViewBuilder
  private var missionsTab: some View {
    let registry = appStore.runtimeRegistry
    if let clients = (registry.primaryRuntime ?? registry.activeRuntime)?.clients {
      MissionListView(missionsClient: clients.missions)
    } else {
      ContentUnavailableView(
        "No Server Connected",
        systemImage: "server.rack",
        description: Text("Connect to a server to view missions")
      )
    }
  }

  // MARK: - Mission Control Layout

  @ViewBuilder
  private func missionControlLayout(
    layoutMode: DashboardLayoutMode,
    containerWidth: CGFloat
  ) -> some View {
    let _ = containerWidth

    VStack(spacing: 0) {
      ActivityStreamToolbar(
        totalCount: viewModel.dashboardConversations.count,
        counts: viewModel.dashboardCounts,
        directCount: viewModel.dashboardDirectCount,
        filter: $viewModel.activeWorkbenchFilter,
        sort: $viewModel.activeSort,
        providerFilter: $viewModel.activeProviderFilter,
        sortOptions: [.recent, .status, .name]
      )

      missionControlScrollView(layoutMode: layoutMode)
    }
  }

  private func sidebarResizeHandle(containerWidth: CGFloat) -> some View {
    DashboardSidebarResizeHandle(
      isActive: sidebarDragStartWidth != nil,
      onDragChanged: { translation in
        let startWidth = sidebarDragStartWidth ?? effectiveSidebarWidth(for: containerWidth)
        if sidebarDragStartWidth == nil {
          sidebarDragStartWidth = startWidth
        }
        sidebarDragWidth = clampSidebarWidth(startWidth + translation, containerWidth: containerWidth)
      },
      onDragEnded: { translation in
        let startWidth = sidebarDragStartWidth ?? effectiveSidebarWidth(for: containerWidth)
        let finalWidth = clampSidebarWidth(startWidth + translation, containerWidth: containerWidth)
        persistedSidebarWidth = Double(finalWidth)
        sidebarDragWidth = nil
        sidebarDragStartWidth = nil
      },
      onReset: {
        persistedSidebarWidth = 244
        sidebarDragWidth = nil
        sidebarDragStartWidth = nil
      }
    )
  }

  private func missionControlScrollView(layoutMode: DashboardLayoutMode) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        if viewModel.showingLoadingSkeleton(isInitialLoading: isInitialLoading) {
          loadingSkeletonContent
        } else {
          MissionControlCommandDeck(
            conversations: viewModel.filteredDashboardConversations,
            projectFilter: $viewModel.activeProjectFilter,
            selectedIndex: viewModel.selectedIndex
          )
        }
      }
      .padding(layoutMode.contentPadding)
      .scrollTargetLayout()
    }
    .scrollContentBackground(.hidden)
    .scrollPosition(id: dashboardScrollAnchorBinding)
    .task {
      viewModel.bind(appStore: appStore)
      if isMissionControlVisible {
        await viewModel.refreshDashboardData()
      }
    }
    .task(id: isMissionControlVisible ? viewModel.dashboardRefreshIdentity : "dashboard-hidden") {
      guard isMissionControlVisible else { return }
      viewModel.bind(appStore: appStore)
      await viewModel.refreshDashboardData()
    }
    .onChange(of: viewModel.selectedIndex) { _, _ in
      guard let targetID = viewModel.selectedConversationScrollTargetID else { return }
      withAnimation(Motion.hover) {
        viewModel.dashboardScrollAnchorID = targetID
      }
    }
    .focusable()
    .focused($isDashboardFocused)
    .onAppear {
      viewModel.bind(appStore: appStore)
      viewModel.dashboardScrollAnchorID = router.dashboardScrollAnchorID
      syncDashboardFocus()
    }
    .onChange(of: router.route) { _, _ in
      if isMissionControlVisible {
        viewModel.dashboardScrollAnchorID = router.dashboardScrollAnchorID
        Task {
          await viewModel.refreshDashboardData()
        }
      }
      syncDashboardFocus()
    }
    .onChange(of: router.dashboardTab) { _, newTab in
      guard newTab == .missionControl else { return }
      Task {
        await viewModel.refreshDashboardData()
      }
    }
    .onChange(of: router.showQuickSwitcher) { _, _ in
      syncDashboardFocus()
    }
    .onChange(of: viewModel.dashboardScrollAnchorID) { _, newAnchorID in
      router.dashboardScrollAnchorID = newAnchorID
    }
    .onChange(of: viewModel.filteredDashboardConversations.count) { _, _ in
      viewModel.syncSelectionBounds()
    }
    .modifier(KeyboardNavigationModifier(
      isEnabled: isDashboardInteractionEnabled,
      onMoveUp: { viewModel.moveSelection(by: -1) },
      onMoveDown: { viewModel.moveSelection(by: 1) },
      onMoveToFirst: { viewModel.moveSelectionToFirst() },
      onMoveToLast: { viewModel.moveSelectionToLast() },
      onSelect: { selectCurrentSession() },
      onRename: {}
    ))
  }

  // MARK: - Loading Skeleton

  private var loadingSkeletonContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      skeletonStreamCards
        .padding(.top, Spacing.md)
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private var skeletonStreamCards: some View {
    VStack(spacing: Spacing.sm) {
      ForEach(0 ..< 4, id: \.self) { _ in
        HStack(spacing: Spacing.md_) {
          Circle()
            .fill(Color.surfaceHover)
            .frame(width: 8, height: 8)

          VStack(alignment: .leading, spacing: Spacing.sm_) {
            skeletonLine(height: 14)
            HStack(spacing: Spacing.sm) {
              skeletonLine(width: 60, height: 10)
              skeletonLine(width: 80, height: 10)
            }
            skeletonLine(width: 200, height: 10)
          }

          Spacer(minLength: 12)

          VStack(alignment: .trailing, spacing: Spacing.sm_) {
            skeletonLine(width: 50, height: 16)
            skeletonLine(width: 30, height: 10)
          }
        }
        .padding(.vertical, Spacing.md_)
        .padding(.horizontal, Spacing.md)
        .background(
          RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
            .fill(Color.backgroundSecondary.opacity(0.3))
            .overlay(
              RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
                .stroke(Color.surfaceBorder.opacity(OpacityTier.subtle), lineWidth: 1)
            )
        )
      }
    }
  }

  private func skeletonLine(width: CGFloat? = nil, height: CGFloat = 12) -> some View {
    RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
      .fill(Color.surfaceHover.opacity(0.9))
      .frame(width: width, height: height)
  }

  // MARK: - Navigation

  private func selectCurrentSession() {
    guard isDashboardInteractionEnabled else { return }
    guard let conversation = viewModel.selectedConversation else { return }
    viewModel.dashboardScrollAnchorID = DashboardScrollIDs.session(conversation.id)
    withAnimation(Motion.standard) {
      router.selectSession(conversation.sessionRef, source: .dashboardKeyboard)
    }
  }

  private func syncDashboardFocus() {
    isDashboardFocused = isDashboardInteractionEnabled
  }

  private func effectiveSidebarWidth(for containerWidth: CGFloat) -> CGFloat {
    clampSidebarWidth(sidebarDragWidth ?? CGFloat(persistedSidebarWidth), containerWidth: containerWidth)
  }

  private func clampSidebarWidth(_ width: CGFloat, containerWidth: CGFloat) -> CGFloat {
    let minimumWidth: CGFloat = 214
    let dynamicMaximum = min(max(containerWidth * 0.30, 248), 360)
    let contentSafeMaximum = max(minimumWidth, containerWidth - 520)
    let maximumWidth = min(dynamicMaximum, contentSafeMaximum)
    return min(max(width, minimumWidth), maximumWidth)
  }
}

private struct DashboardSidebarResizeHandle: View {
  let isActive: Bool
  let onDragChanged: (CGFloat) -> Void
  let onDragEnded: (CGFloat) -> Void
  let onReset: () -> Void

  @State private var isHovered = false

  var body: some View {
    ZStack {
      Rectangle()
        .fill(Color.surfaceBorder.opacity(isActive || isHovered ? OpacityTier.medium : OpacityTier.subtle))
        .frame(width: 1)

      RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
        .fill(Color.backgroundSecondary.opacity(isActive || isHovered ? 0.92 : 0.72))
        .frame(width: 12, height: 64)
        .overlay(
          VStack(spacing: 4) {
            Capsule(style: .continuous)
              .fill(Color.textQuaternary)
              .frame(width: 2, height: 16)
            Capsule(style: .continuous)
              .fill(Color.textQuaternary.opacity(0.82))
              .frame(width: 2, height: 16)
          }
        )
        .overlay(
          RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            .stroke(
              Color.surfaceBorder.opacity(isActive || isHovered ? OpacityTier.strong : OpacityTier.light),
              lineWidth: 1
            )
        )
        .shadow(color: Color.black.opacity(isActive ? 0.18 : 0.10), radius: isActive ? 8 : 4, y: 1)
        .opacity(isActive || isHovered ? 1.0 : 0.82)
    }
    .frame(width: 14)
    .contentShape(Rectangle())
    .gesture(
      DragGesture(minimumDistance: 0)
        .onChanged { value in
          onDragChanged(value.translation.width)
        }
        .onEnded { value in
          onDragEnded(value.translation.width)
        }
    )
    .onTapGesture(count: 2, perform: onReset)
    #if os(macOS)
      .onHover { hovering in
        isHovered = hovering
      }
    #endif
      .accessibilityLabel("Resize sidebar")
      .accessibilityHint("Drag to change the mission control sidebar width. Double click to reset.")
  }
}

#Preview {
  let runtimeRegistry = ServerRuntimeRegistry(
    endpointsProvider: { [] },
    runtimeFactory: { ServerRuntime(endpoint: $0) },
    shouldBootstrapFromSettings: false
  )
  let router = AppRouter()
  DashboardView(
    isInitialLoading: false,
    isRefreshingCachedSessions: false
  )
  .frame(width: 900, height: 500)
  .environment(runtimeRegistry)
  .environment(router)
}
