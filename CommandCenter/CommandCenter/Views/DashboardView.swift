//
//  DashboardView.swift
//  OrbitDock
//
//  Home view for active and ended sessions.
//

import SwiftUI

struct DashboardView: View {
  let sessions: [Session]
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

      if !sessions.isEmpty {
        HStack(spacing: 12) {
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
    onSelectSession: { _ in },
    onOpenQuickSwitcher: {},
    onOpenPanel: {}
  )
  .frame(width: 900, height: 500)
}
