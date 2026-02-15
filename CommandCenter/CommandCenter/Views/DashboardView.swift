//
//  DashboardView.swift
//  OrbitDock
//
//  Home view for active and ended sessions.
//

import SwiftUI

struct DashboardView: View {
  let sessions: [Session]
  let isInitialLoading: Bool
  let isRefreshingCachedSessions: Bool
  let onSelectSession: (String) -> Void
  let onOpenQuickSwitcher: () -> Void
  let onOpenPanel: () -> Void

  @State private var selectedIndex = 0
  @State private var showNewCodexSheet = false
  @FocusState private var isDashboardFocused: Bool

  private var activeSessions: [Session] {
    sessions
      .filter(\.isActive)
      .sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
  }

  private var showingLoadingSkeleton: Bool {
    isInitialLoading && sessions.isEmpty
  }

  var body: some View {
    VStack(spacing: 0) {
      dashboardHeader

      Divider()
        .foregroundStyle(Color.panelBorder)

      sessionsContent
    }
    .background(Color.backgroundPrimary)
    .sheet(isPresented: $showNewCodexSheet) {
      NewCodexSessionSheet()
    }
  }

  private var sessionsContent: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          if showingLoadingSkeleton {
            loadingSkeletonContent
          } else {
            CommandBar(sessions: sessions)

            ActiveSessionsSection(
              sessions: sessions,
              onSelectSession: onSelectSession,
              selectedIndex: selectedIndex
            )

            SessionHistorySection(
              sessions: sessions,
              onSelectSession: onSelectSession
            )
          }
        }
        .padding(24)
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

  private var dashboardHeader: some View {
    HStack(spacing: 12) {
      Button {
        onOpenPanel()
      } label: {
        Image(systemName: "sidebar.left")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.secondary)
          .frame(width: 28, height: 28)
          .background(Color.surfaceHover, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      }
      .buttonStyle(.plain)
      .help("Toggle panel (⌘1)")

      Text("OrbitDock")
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.primary)

      Spacer()

      if showingLoadingSkeleton || isRefreshingCachedSessions || !sessions.isEmpty {
        HStack(spacing: 12) {
          if showingLoadingSkeleton || isRefreshingCachedSessions {
            HStack(spacing: 6) {
              ProgressView()
                .controlSize(.small)
              Text("Syncing")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            }
          }

          let workingCount = sessions.filter { SessionDisplayStatus.from($0) == .working }.count
          let attentionCount = sessions.filter { SessionDisplayStatus.from($0) == .attention }.count

          if workingCount > 0 {
            HStack(spacing: 4) {
              Circle()
                .fill(Color.statusWorking)
                .frame(width: 6, height: 6)
              Text("\(workingCount)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
              Text("Working")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            }
          }

          if attentionCount > 0 {
            HStack(spacing: 4) {
              Circle()
                .fill(Color.statusAttention)
                .frame(width: 6, height: 6)
              Text("\(attentionCount)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
              Text("Attention")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            }
          }
        }
      }

      Button {
        showNewCodexSheet = true
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "plus")
            .font(.system(size: 11, weight: .bold))
          Text("Codex")
            .font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .foregroundStyle(Color.accent)
      }
      .buttonStyle(.plain)
      .help("Create new Codex session")

      Button {
        onOpenQuickSwitcher()
      } label: {
        HStack(spacing: 6) {
          Image(systemName: "magnifyingglass")
            .font(.system(size: 11, weight: .medium))
          Text("Search")
            .font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(Color.backgroundSecondary)
  }

  private var loadingSkeletonContent: some View {
    VStack(alignment: .leading, spacing: 20) {
      skeletonCommandBarCard
      skeletonActiveSection
      skeletonHistorySection
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private var skeletonCommandBarCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        skeletonLine(width: 180, height: 14)
        Spacer()
        skeletonLine(width: 56, height: 14)
      }

      HStack(spacing: 16) {
        ForEach(0 ..< 4, id: \.self) { _ in
          VStack(alignment: .leading, spacing: 8) {
            skeletonLine(width: 44, height: 10)
            skeletonLine(width: 64, height: 12)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .padding(16)
    .background(Color.backgroundTertiary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private var skeletonActiveSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Circle()
          .fill(Color.surfaceHover)
          .frame(width: 10, height: 10)
        skeletonLine(width: 140, height: 13)
        Spacer()
        skeletonLine(width: 28, height: 13)
        skeletonLine(width: 28, height: 13)
        skeletonLine(width: 28, height: 13)
      }
      .padding(.vertical, 10)
      .padding(.horizontal, 14)
      .background(Color.backgroundTertiary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

      VStack(spacing: 6) {
        ForEach(0 ..< 3, id: \.self) { _ in
          HStack(spacing: 10) {
            Circle()
              .fill(Color.surfaceHover)
              .frame(width: 8, height: 8)
              .frame(width: 14)

            VStack(alignment: .leading, spacing: 6) {
              skeletonLine(height: 13)
              skeletonLine(width: 160, height: 10)
            }

            Spacer(minLength: 12)

            skeletonLine(width: 78, height: 20)
          }
          .padding(12)
          .background(Color.backgroundSecondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
