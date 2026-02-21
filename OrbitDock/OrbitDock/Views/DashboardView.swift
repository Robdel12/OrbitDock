//
//  DashboardView.swift
//  OrbitDock
//
//  Home view — project-first flat layout with attention interrupts.
//

import SwiftUI

struct DashboardView: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  let sessions: [Session]
  let isInitialLoading: Bool
  let isRefreshingCachedSessions: Bool
  let onSelectSession: (String) -> Void
  let onOpenQuickSwitcher: () -> Void
  let onOpenPanel: () -> Void

  @StateObject private var connection = ServerConnection.shared
  @State private var selectedIndex = 0
  @State private var showNewCodexSheet = false
  @State private var showNewClaudeSheet = false
  @State private var activeWorkbenchFilter: ActiveSessionWorkbenchFilter = .all
  @State private var activeSort: ActiveSessionSort = .status
  @State private var activeProviderFilter: ActiveSessionProviderFilter = .all
  @FocusState private var isDashboardFocused: Bool

  private var activeSessions: [Session] {
    ProjectStreamSection.keyboardNavigableSessions(
      from: sessions,
      filter: activeWorkbenchFilter,
      sort: activeSort,
      providerFilter: activeProviderFilter
    )
  }

  private var showingLoadingSkeleton: Bool {
    isInitialLoading && sessions.isEmpty
  }

  private var layoutMode: DashboardLayoutMode {
    DashboardLayoutMode.current(horizontalSizeClass: horizontalSizeClass)
  }

  var body: some View {
    VStack(spacing: 0) {
      CommandStrip(
        sessions: sessions,
        isInitialLoading: isInitialLoading,
        isRefreshingCachedSessions: isRefreshingCachedSessions,
        onOpenPanel: onOpenPanel,
        onOpenQuickSwitcher: onOpenQuickSwitcher,
        onNewClaude: { showNewClaudeSheet = true },
        onNewCodex: { showNewCodexSheet = true }
      )

      Divider()
        .foregroundStyle(Color.panelBorder)

      if !layoutMode.isPhoneCompact {
        connectionBanner
      }

      sessionsContent
    }
    .background(Color.backgroundPrimary)
    .sheet(isPresented: $showNewCodexSheet) {
      NewCodexSessionSheet()
    }
    .sheet(isPresented: $showNewClaudeSheet) {
      NewClaudeSessionSheet()
    }
  }

  private var sessionsContent: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          if showingLoadingSkeleton {
            loadingSkeletonContent
          } else {
            // Zone 1: Ambient stats — recessed metadata strip
            if !layoutMode.isPhoneCompact {
              CommandBar(sessions: sessions)
            }

            // Zone 2: Attention interrupts — the real priority
            AttentionBanner(
              sessions: sessions,
              onSelectSession: onSelectSession
            )
            .padding(.top, layoutMode.attentionTopPadding)

            // Zone 3: Active agents — primary content
            ProjectStreamSection(
              sessions: sessions,
              onSelectSession: onSelectSession,
              selectedIndex: selectedIndex,
              filter: $activeWorkbenchFilter,
              sort: $activeSort,
              providerFilter: $activeProviderFilter
            )
            .padding(.top, layoutMode.activeTopPadding)

            // Zone 4: History
            SessionHistorySection(
              sessions: sessions,
              onSelectSession: onSelectSession
            )
            .padding(.top, layoutMode.historyTopPadding)
          }
        }
        .padding(layoutMode.contentPadding)
      }
      .scrollContentBackground(.hidden)
      .onChange(of: selectedIndex) { _, newIndex in
        withAnimation(.easeOut(duration: 0.15)) {
          proxy.scrollTo("active-session-\(newIndex)", anchor: .center)
        }
      }
    }
    .focusable()
    .focused($isDashboardFocused)
    .onAppear {
      isDashboardFocused = true
    }
    .onChange(of: activeSessions.count) { _, newCount in
      if selectedIndex >= newCount, newCount > 0 {
        selectedIndex = newCount - 1
      }
    }
    .modifier(KeyboardNavigationModifier(
      onMoveUp: { moveSelection(by: -1) },
      onMoveDown: { moveSelection(by: 1) },
      onMoveToFirst: { selectedIndex = 0 },
      onMoveToLast: {
        if !activeSessions.isEmpty {
          selectedIndex = activeSessions.count - 1
        }
      },
      onSelect: { selectCurrentSession() },
      onRename: {}
    ))
  }

  // MARK: - Loading Skeleton

  private var loadingSkeletonContent: some View {
    VStack(alignment: .leading, spacing: 0) {
      skeletonCommandBarCard
      skeletonProjectStream
        .padding(.top, 20)
      skeletonHistorySection
        .padding(.top, 24)
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private var skeletonCommandBarCard: some View {
    HStack(spacing: 16) {
      skeletonLine(width: 180, height: 12)
      Spacer()
      skeletonLine(width: 120, height: 28)
      skeletonLine(width: 120, height: 28)
    }
    .padding(.horizontal, 2)
    .padding(.vertical, 6)
  }

  private var skeletonProjectStream: some View {
    VStack(alignment: .leading, spacing: 12) {
      // Section header skeleton
      HStack(spacing: 8) {
        Circle()
          .fill(Color.surfaceHover)
          .frame(width: 10, height: 10)
        skeletonLine(width: 120, height: 13)
        Spacer()
        skeletonLine(width: 28, height: 13)
        skeletonLine(width: 28, height: 13)
      }
      .padding(.vertical, 10)
      .padding(.horizontal, 2)

      // Project header skeleton
      HStack(spacing: 8) {
        skeletonLine(width: 3, height: 14)
        skeletonLine(width: 100, height: 12)
        skeletonLine(width: 50, height: 10)
        Spacer()
      }
      .padding(.horizontal, 10)

      // Flat session row skeletons
      VStack(spacing: 2) {
        ForEach(0 ..< 3, id: \.self) { _ in
          HStack(spacing: 10) {
            Circle()
              .fill(Color.surfaceHover)
              .frame(width: 8, height: 8)

            skeletonLine(height: 12)

            Spacer(minLength: 12)

            skeletonLine(width: 50, height: 10)
            skeletonLine(width: 60, height: 16)
            skeletonLine(width: 40, height: 10)
          }
          .padding(.vertical, 7)
          .padding(.horizontal, 10)
        }
      }
    }
  }

  private var skeletonHistorySection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        skeletonLine(width: 150, height: 13)
        Spacer()
        skeletonLine(width: 36, height: 13)
      }
      .padding(.vertical, 10)
      .padding(.horizontal, 14)
      .background(Color.backgroundTertiary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

      VStack(spacing: 8) {
        ForEach(0 ..< 2, id: \.self) { _ in
          HStack(spacing: 10) {
            skeletonLine(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 6) {
              skeletonLine(height: 12)
              skeletonLine(width: 180, height: 10)
            }
            Spacer()
            skeletonLine(width: 48, height: 10)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 10)
          .background(Color.backgroundSecondary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
      }
    }
  }

  private func skeletonLine(width: CGFloat? = nil, height: CGFloat = 12) -> some View {
    RoundedRectangle(cornerRadius: 4, style: .continuous)
      .fill(Color.surfaceHover.opacity(0.9))
      .frame(width: width, height: height)
  }

  // MARK: - Connection Banner

  @ViewBuilder
  private var connectionBanner: some View {
    switch connection.status {
      case .connected:
        EmptyView()
      case .connecting:
        connectionBannerRow(
          icon: "antenna.radiowaves.left.and.right",
          color: Color.statusQuestion,
          message: "Connecting to server...",
          showSpinner: true
        )
      case .disconnected:
        connectionBannerRow(
          icon: "bolt.slash.fill",
          color: Color.textTertiary,
          message: "Disconnected",
          action: ("Connect", { ServerConnection.shared.connect() })
        )
      case let .failed(reason):
        connectionBannerRow(
          icon: "exclamationmark.triangle.fill",
          color: Color.statusPermission,
          message: reason,
          action: ("Retry", { ServerConnection.shared.connect() })
        )
    }
  }

  private func connectionBannerRow(
    icon: String,
    color: Color,
    message: String,
    showSpinner: Bool = false,
    action: (String, () -> Void)? = nil
  ) -> some View {
    HStack(spacing: 8) {
      if showSpinner {
        ProgressView()
          .controlSize(.mini)
          .tint(color)
      } else {
        Image(systemName: icon)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(color)
      }

      Text(message)
        .font(.system(size: TypeScale.caption, weight: .medium))
        .foregroundStyle(color)
        .lineLimit(1)

      Spacer()

      if let (label, handler) = action {
        Button(action: handler) {
          Text(label)
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
              Color.accent.opacity(OpacityTier.light),
              in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            )
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(color.opacity(0.08))
  }

  // MARK: - Navigation

  private func moveSelection(by delta: Int) {
    guard !activeSessions.isEmpty else { return }
    let newIndex = selectedIndex + delta
    if newIndex < 0 {
      selectedIndex = activeSessions.count - 1
    } else if newIndex >= activeSessions.count {
      selectedIndex = 0
    } else {
      selectedIndex = newIndex
    }
  }

  private func selectCurrentSession() {
    guard selectedIndex >= 0, selectedIndex < activeSessions.count else { return }
    let session = activeSessions[selectedIndex]
    onSelectSession(session.id)
  }
}

#Preview {
  DashboardView(
    sessions: [],
    isInitialLoading: false,
    isRefreshingCachedSessions: false,
    onSelectSession: { _ in },
    onOpenQuickSwitcher: {},
    onOpenPanel: {}
  )
  .frame(width: 900, height: 500)
}
