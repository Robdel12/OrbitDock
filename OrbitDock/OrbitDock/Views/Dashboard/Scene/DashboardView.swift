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
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry
  @Environment(AppRouter.self) private var router

  let sessions: [Session]
  let endpointHealth: [UnifiedEndpointHealth]
  let isInitialLoading: Bool
  let isRefreshingCachedSessions: Bool

  // Mission control state
  @State private var selectedIndex = 0
  @State private var dashboardScrollAnchorID: String?
  @State private var activeWorkbenchFilter: ActiveSessionWorkbenchFilter = .all
  @State private var activeSort: ActiveSessionSort = .recent
  @State private var activeProviderFilter: ActiveSessionProviderFilter = .all
  @State private var activeProjectFilter: String?
  @State private var sidebarDragWidth: CGFloat?
  @State private var sidebarDragStartWidth: CGFloat?
  @FocusState private var isDashboardFocused: Bool
  @AppStorage("dashboard.missionControl.sidebarWidth") private var persistedSidebarWidth: Double = 244

  private var activityStream: ActivityStream {
    ActivityStream.build(
      from: sessions,
      filter: activeWorkbenchFilter,
      sort: activeSort,
      providerFilter: activeProviderFilter,
      projectFilter: activeProjectFilter
    )
  }

  private var navigableSessions: [Session] {
    activityStream.attention + activityStream.working + activityStream.ready
  }

  private var showingLoadingSkeleton: Bool {
    isInitialLoading && sessions.isEmpty
  }

  private var dashboardScrollAnchorBinding: Binding<String?> {
    Binding(
      get: { dashboardScrollAnchorID },
      set: { dashboardScrollAnchorID = $0 }
    )
  }

  var body: some View {
    GeometryReader { proxy in
      let containerWidth = proxy.size.width
      let layoutMode = DashboardLayoutMode.current(
        horizontalSizeClass: horizontalSizeClass,
        containerWidth: containerWidth
      )

      VStack(spacing: 0) {
        DashboardStatusBar(
          sessions: sessions,
          isInitialLoading: isInitialLoading,
          isRefreshingCachedSessions: isRefreshingCachedSessions
        )

        switch router.dashboardTab {
          case .missionControl:
            missionControlLayout(
              layoutMode: layoutMode,
              containerWidth: containerWidth
            )
          case .library:
            LibraryView(
              sessions: sessions,
              containerWidth: containerWidth
            )
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Color.backgroundPrimary)
    }
  }

  // MARK: - Mission Control Layout

  @ViewBuilder
  private func missionControlLayout(
    layoutMode: DashboardLayoutMode,
    containerWidth: CGFloat
  ) -> some View {
    let showsSidebar = DashboardLayoutMode.shouldShowMissionControlSidebar(
      horizontalSizeClass: horizontalSizeClass,
      containerWidth: containerWidth
    )
    let sidebarWidth = effectiveSidebarWidth(for: containerWidth)

    Group {
      if showsSidebar {
        HStack(spacing: 0) {
          DesktopSidebarPanel(
            sessions: sessions,
            width: sidebarWidth,
            projectFilter: $activeProjectFilter,
            onSelectSession: { session in
              withAnimation(Motion.hover) {
                dashboardScrollAnchorID = DashboardScrollIDs.session(session.scopedID)
              }
            }
          )

          #if os(macOS)
            sidebarResizeHandle(containerWidth: containerWidth)
          #endif

          VStack(spacing: 0) {
            ActivityStreamToolbar(
              sessions: sessions,
              filter: $activeWorkbenchFilter,
              sort: $activeSort,
              providerFilter: $activeProviderFilter
            )

            missionControlScrollView(layoutMode: layoutMode)
          }
        }
      } else {
        VStack(spacing: 0) {
          ActivityStreamToolbar(
            sessions: sessions,
            filter: $activeWorkbenchFilter,
            sort: $activeSort,
            providerFilter: $activeProviderFilter
          )

          missionControlScrollView(layoutMode: layoutMode)
        }
      }
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
        if showingLoadingSkeleton {
          loadingSkeletonContent
        } else {
          ActivityStreamContent(
            sessions: sessions,
            filter: activeWorkbenchFilter,
            sort: activeSort,
            providerFilter: activeProviderFilter,
            projectFilter: activeProjectFilter,
            selectedIndex: selectedIndex
          )
        }
      }
      .padding(layoutMode.contentPadding)
      .scrollTargetLayout()
    }
    .scrollContentBackground(.hidden)
    .scrollPosition(id: dashboardScrollAnchorBinding)
    .onChange(of: selectedIndex) { _, newIndex in
      guard newIndex >= 0, newIndex < navigableSessions.count else { return }
      let targetID = DashboardScrollIDs.session(navigableSessions[newIndex].scopedID)
      withAnimation(Motion.hover) {
        dashboardScrollAnchorID = targetID
      }
    }
    .focusable()
    .focused($isDashboardFocused)
    .onAppear {
      isDashboardFocused = true
      dashboardScrollAnchorID = router.dashboardScrollAnchorID
    }
    .onChange(of: dashboardScrollAnchorID) { _, newAnchorID in
      router.dashboardScrollAnchorID = newAnchorID
    }
    .onChange(of: navigableSessions.count) { _, newCount in
      if selectedIndex >= newCount, newCount > 0 {
        selectedIndex = newCount - 1
      }
    }
    .modifier(KeyboardNavigationModifier(
      onMoveUp: { moveSelection(by: -1) },
      onMoveDown: { moveSelection(by: 1) },
      onMoveToFirst: { selectedIndex = 0 },
      onMoveToLast: {
        if !navigableSessions.isEmpty {
          selectedIndex = navigableSessions.count - 1
        }
      },
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

  private func moveSelection(by delta: Int) {
    guard !navigableSessions.isEmpty else { return }
    let newIndex = selectedIndex + delta
    if newIndex < 0 {
      selectedIndex = navigableSessions.count - 1
    } else if newIndex >= navigableSessions.count {
      selectedIndex = 0
    } else {
      selectedIndex = newIndex
    }
  }

  private func selectCurrentSession() {
    guard selectedIndex >= 0, selectedIndex < navigableSessions.count else { return }
    let session = navigableSessions[selectedIndex]
    dashboardScrollAnchorID = DashboardScrollIDs.session(session.scopedID)
    withAnimation(Motion.standard) {
      router.navigateToSession(scopedID: session.scopedID, runtimeRegistry: runtimeRegistry)
    }
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
            .stroke(Color.surfaceBorder.opacity(isActive || isHovered ? OpacityTier.strong : OpacityTier.light), lineWidth: 1)
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
  DashboardView(
    sessions: [],
    endpointHealth: [],
    isInitialLoading: false,
    isRefreshingCachedSessions: false
  )
  .frame(width: 900, height: 500)
  .environment(ServerRuntimeRegistry.shared)
  .environment(AppRouter())
}
