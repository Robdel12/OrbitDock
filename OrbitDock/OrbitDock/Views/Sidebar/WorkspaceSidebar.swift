//
//  WorkspaceSidebar.swift
//  OrbitDock
//
//  Persistent workspace control surface — attention queue, project groups,
//  usage bars, and quick actions in a single always-available panel.
//

import SwiftUI

struct WorkspaceSidebar: View {
  @Environment(ServerAppState.self) private var serverState
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry

  let sessions: [Session]
  let selectedSessionId: String?
  let onSelectSession: (String) -> Void
  let onCollapse: () -> Void
  let onNewClaude: () -> Void
  let onNewCodex: () -> Void

  @State private var searchText = ""
  @State private var renamingSession: Session?
  @State private var renameText = ""
  @State private var showRecentSessions = false
  @State private var showServerSettings = false
  @State private var showAppSettings = false

  private let registry = UsageServiceRegistry.shared

  // MARK: - Derived Data

  private var attentionSessions: [Session] {
    sessions.filter(\.needsAttention)
  }

  private var activeSessions: [Session] {
    sessions.filter(\.isActive)
  }

  private var recentSessions: [Session] {
    sessions.filter { !$0.isActive }
      .sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
      .prefix(5)
      .map { $0 }
  }

  private var projectGroups: [ProjectGroup] {
    ProjectStreamSection.makeProjectGroups(from: activeSessions, sort: .status)
  }

  private var filteredSessions: [Session] {
    guard !searchText.isEmpty else { return [] }
    return sessions.filter {
      $0.displayName.localizedCaseInsensitiveContains(searchText) ||
        $0.projectPath.localizedCaseInsensitiveContains(searchText) ||
        ($0.branch ?? "").localizedCaseInsensitiveContains(searchText) ||
        ($0.summary ?? "").localizedCaseInsensitiveContains(searchText) ||
        ($0.customName ?? "").localizedCaseInsensitiveContains(searchText)
    }
  }

  private var enabledRuntimes: [ServerRuntime] {
    runtimeRegistry.runtimes.filter(\.endpoint.isEnabled)
  }

  // MARK: - Body

  var body: some View {
    VStack(spacing: 0) {
      sidebarHeader
      Divider().foregroundStyle(Color.panelBorder)
      searchBar
      Divider().foregroundStyle(Color.panelBorder)

      // Scrollable content
      ScrollView {
        LazyVStack(spacing: 0) {
          if !searchText.isEmpty {
            searchResults
          } else {
            mainContent
          }
        }
        .padding(.vertical, 4)
      }
      .scrollContentBackground(.hidden)

      Divider().foregroundStyle(Color.panelBorder)
      usageSection
      Divider().foregroundStyle(Color.panelBorder)
      quickActions
    }
    .frame(width: 320)
    .background(Color.panelBackground)
    .sheet(item: $renamingSession) { session in
      RenameSessionSheet(
        session: session,
        initialText: renameText,
        onSave: { newName in
          let name = newName.isEmpty ? nil : newName
          appState(for: session).renameSession(sessionId: session.id, name: name)
          renamingSession = nil
        },
        onCancel: {
          renamingSession = nil
        }
      )
    }
    .sheet(isPresented: $showServerSettings) {
      ServerSettingsSheet()
    }
    .sheet(isPresented: $showAppSettings) {
      SettingsView(showsCloseButton: true)
    }
  }

  // MARK: - Header

  private var sidebarHeader: some View {
    HStack(spacing: 8) {
      Text("Workspace")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.primary)

      Spacer()

      // Endpoint health dots
      endpointHealthDots

      // Collapse button
      Button(action: onCollapse) {
        Image(systemName: "sidebar.left")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(Color.textTertiary)
          .frame(width: 24, height: 24)
      }
      .buttonStyle(.plain)
      .help("Toggle sidebar (⌘1)")
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  @ViewBuilder
  private var endpointHealthDots: some View {
    if enabledRuntimes.count > 1 {
      HStack(spacing: 4) {
        ForEach(enabledRuntimes, id: \.endpoint.id) { runtime in
          let status = runtimeRegistry.connectionStatusByEndpointId[runtime.endpoint.id] ?? runtime.connection.status
          Circle()
            .fill(connectionColor(status))
            .frame(width: 6, height: 6)
            .help("\(runtime.endpoint.name): \(connectionLabel(status))")
        }
      }
    } else if let runtime = enabledRuntimes.first {
      let status = runtimeRegistry.connectionStatusByEndpointId[runtime.endpoint.id] ?? runtime.connection.status
      Circle()
        .fill(connectionColor(status))
        .frame(width: 6, height: 6)
        .help(connectionLabel(status))
    }
  }

  // MARK: - Search

  private var searchBar: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Color.textTertiary)

      TextField("Search sessions...", text: $searchText)
        .textFieldStyle(.plain)
        .font(.system(size: 12))
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  // MARK: - Main Content (non-search)

  private var mainContent: some View {
    VStack(spacing: 0) {
      // Attention queue
      if !attentionSessions.isEmpty {
        attentionSection
      }

      // Active project groups
      if !projectGroups.isEmpty {
        projectSection
      }

      // Empty state
      if activeSessions.isEmpty && attentionSessions.isEmpty {
        emptyState
      }

      // Recent (collapsed by default)
      if !recentSessions.isEmpty {
        recentSection
      }
    }
  }

  // MARK: - Attention Queue

  private var attentionSection: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Image(systemName: "exclamationmark.circle.fill")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(Color.statusPermission)

        Text("ATTENTION")
          .font(.system(size: 10, weight: .bold, design: .rounded))
          .foregroundStyle(Color.statusPermission.opacity(0.9))
          .tracking(0.5)

        Text("\(attentionSessions.count)")
          .font(.system(size: 9, weight: .bold, design: .rounded))
          .foregroundStyle(Color.statusPermission)

        Spacer()
      }
      .padding(.horizontal, 14)
      .padding(.top, 10)
      .padding(.bottom, 4)

      ForEach(attentionSessions, id: \.scopedID) { session in
        SidebarAttentionRow(
          session: session,
          isSelected: selectedSessionId == session.scopedID,
          onSelect: { onSelectSession(session.scopedID) }
        )
        .padding(.horizontal, 8)
      }
    }
    .padding(.bottom, 8)
  }

  // MARK: - Project Groups

  private var projectSection: some View {
    VStack(spacing: 2) {
      ForEach(projectGroups) { group in
        SidebarProjectGroup(
          group: group,
          selectedSessionId: selectedSessionId,
          onSelectSession: onSelectSession,
          onRenameSession: { session in
            renameText = session.customName ?? ""
            renamingSession = session
          }
        )
      }
    }
    .padding(.vertical, 4)
  }

  // MARK: - Recent Sessions

  private var recentSection: some View {
    VStack(alignment: .leading, spacing: 4) {
      Button {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
          showRecentSessions.toggle()
        }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: showRecentSessions ? "chevron.down" : "chevron.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Color.textQuaternary)
            .frame(width: 10)

          Text("Recent")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color.textTertiary)

          Text("\(recentSessions.count)")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(Color.textQuaternary)

          Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if showRecentSessions {
        ForEach(recentSessions, id: \.scopedID) { session in
          SidebarSessionRow(
            session: session,
            isSelected: selectedSessionId == session.scopedID,
            onSelect: { onSelectSession(session.scopedID) },
            onRename: {
              renameText = session.customName ?? ""
              renamingSession = session
            }
          )
          .padding(.horizontal, 8)
        }
      }
    }
    .padding(.top, 8)
  }

  // MARK: - Search Results

  private var searchResults: some View {
    VStack(spacing: 2) {
      ForEach(filteredSessions, id: \.scopedID) { session in
        SidebarSessionRow(
          session: session,
          isSelected: selectedSessionId == session.scopedID,
          onSelect: { onSelectSession(session.scopedID) },
          onRename: {
            renameText = session.customName ?? ""
            renamingSession = session
          }
        )
        .padding(.horizontal, 8)
      }

      if filteredSessions.isEmpty {
        VStack(spacing: 8) {
          Image(systemName: "magnifyingglass")
            .font(.system(size: 20))
            .foregroundStyle(Color.textQuaternary)

          Text("No matching sessions")
            .font(.system(size: 12))
            .foregroundStyle(Color.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
      }
    }
  }

  // MARK: - Usage Section (pinned bottom)

  private var usageSection: some View {
    VStack(spacing: 4) {
      ForEach(registry.activeProviders) { provider in
        ProviderUsageCompact(
          provider: provider,
          windows: registry.windows(for: provider),
          isLoading: registry.isLoading(for: provider),
          error: registry.error(for: provider),
          isStale: registry.isStale(for: provider)
        )
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
  }

  // MARK: - Quick Actions (pinned bottom)

  private var quickActions: some View {
    HStack(spacing: 8) {
      // New session menu
      Menu {
        Button {
          onNewClaude()
        } label: {
          Label("New Claude Session", systemImage: "staroflife.fill")
        }

        Button {
          onNewCodex()
        } label: {
          Label("New Codex Session", systemImage: "chevron.left.forwardslash.chevron.right")
        }
      } label: {
        HStack(spacing: 4) {
          Image(systemName: "plus")
            .font(.system(size: 10, weight: .bold))
          Text("New")
            .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(Color.accent)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      }
      .menuStyle(.borderlessButton)
      .fixedSize()

      Spacer()

      // Settings
      Button {
        showAppSettings = true
      } label: {
        Image(systemName: "gearshape")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(Color.textTertiary)
          .frame(width: 28, height: 28)
      }
      .buttonStyle(.plain)
      .help("Settings")

      // Server settings
      Button {
        showServerSettings = true
      } label: {
        Image(systemName: "server.rack")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(Color.textTertiary)
          .frame(width: 28, height: 28)
      }
      .buttonStyle(.plain)
      .help("Server Settings")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  // MARK: - Empty State

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "terminal")
        .font(.system(size: 28))
        .foregroundStyle(Color.textQuaternary)

      VStack(spacing: 4) {
        Text("No Active Sessions")
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(.secondary)

        Text("Start an AI session\nto see it here")
          .font(.system(size: 11))
          .foregroundStyle(Color.textTertiary)
          .multilineTextAlignment(.center)
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 40)
  }

  // MARK: - Helpers

  private func appState(for session: Session) -> ServerAppState {
    runtimeRegistry.appState(for: session, fallback: serverState)
  }

  private func connectionColor(_ status: ConnectionStatus) -> Color {
    switch status {
      case .connected: .statusSuccess
      case .connecting: .statusWaiting
      case .disconnected: .statusError
      case .failed: .statusError
    }
  }

  private func connectionLabel(_ status: ConnectionStatus) -> String {
    switch status {
      case .connected: "Connected"
      case .connecting: "Connecting..."
      case .disconnected: "Disconnected"
      case .failed(let msg): "Failed: \(msg)"
    }
  }
}

#Preview {
  HStack(spacing: 0) {
    WorkspaceSidebar(
      sessions: [
        Session(
          id: "1",
          projectPath: "/Users/dev/OrbitDock",
          projectName: "OrbitDock",
          branch: "feat/sidebar",
          model: "claude-opus-4-5-20251101",
          contextLabel: "Sidebar Redesign",
          transcriptPath: nil,
          status: .active,
          workStatus: .working,
          startedAt: Date(),
          endedAt: nil,
          endReason: nil,
          totalTokens: 0,
          totalCostUSD: 0,
          lastActivityAt: nil,
          lastTool: nil,
          lastToolAt: nil,
          promptCount: 0,
          toolCount: 0,
          terminalSessionId: nil,
          terminalApp: nil
        ),
        Session(
          id: "2",
          projectPath: "/Users/dev/vizzly-cli",
          projectName: "vizzly-cli",
          branch: "main",
          model: "claude-sonnet-4-20250514",
          contextLabel: "Visual Testing",
          transcriptPath: nil,
          status: .active,
          workStatus: .permission,
          startedAt: Date(),
          endedAt: nil,
          endReason: nil,
          totalTokens: 0,
          totalCostUSD: 0,
          lastActivityAt: nil,
          lastTool: "Bash",
          lastToolAt: Date().addingTimeInterval(-180),
          promptCount: 0,
          toolCount: 0,
          terminalSessionId: nil,
          terminalApp: nil
        ),
      ],
      selectedSessionId: "1",
      onSelectSession: { _ in },
      onCollapse: {},
      onNewClaude: {},
      onNewCodex: {}
    )

    Rectangle()
      .fill(Color.backgroundPrimary)
  }
  .frame(width: 700, height: 600)
  .environment(ServerAppState())
  .environment(ServerRuntimeRegistry.shared)
}
