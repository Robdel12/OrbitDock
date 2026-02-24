//
//  ContentView.swift
//  OrbitDock
//
//  Created by Robert DeLuca on 1/30/26.
//

import SwiftUI

struct ContentView: View {
  @Environment(ServerAppState.self) private var serverState
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry
  @Environment(AttentionService.self) private var attentionService
  @StateObject private var serverManager = ServerManager.shared
  @State private var unifiedSessionsStore = UnifiedSessionsStore()
  @State private var sessions: [Session] = []
  @State private var selectedSessionScopedID: String?
  @StateObject private var toastManager = ToastManager.shared

  // Panel state
  @State private var showAgentPanel = false
  @State private var showQuickSwitcher = false

  // New session sheet state (moved from DashboardView for QuickSwitcher access)
  @State private var showNewClaudeSheet = false
  @State private var showNewCodexSheet = false

  /// Resolve ID to fresh session object from current sessions array
  private var selectedSession: Session? {
    guard let ref = selectedSessionRef else { return nil }
    guard let runtime = runtimeRegistry.runtimesByEndpointId[ref.endpointId] else { return nil }
    guard var session = runtime.appState.sessions.first(where: { $0.id == ref.sessionId }) else { return nil }
    session.endpointId = runtime.endpoint.id
    session.endpointName = runtime.endpoint.name
    return session
  }

  private var selectedSessionRef: SessionRef? {
    guard let selectedSessionScopedID else { return nil }
    return unifiedSessionsStore.sessionRef(for: selectedSessionScopedID)
  }

  var workingSessions: [Session] {
    sessions.filter { $0.isActive && $0.workStatus == .working }
  }

  var waitingSessions: [Session] {
    sessions.filter(\.needsAttention)
  }

  private var enabledRuntimes: [ServerRuntime] {
    runtimeRegistry.runtimes.filter(\.endpoint.isEnabled)
  }

  private var isAnyInitialLoading: Bool {
    enabledRuntimes.contains { $0.appState.isLoadingInitialSessions }
  }

  private var isAnyRefreshingCachedSessions: Bool {
    enabledRuntimes.contains { $0.appState.isRefreshingCachedSessions }
  }

  /// Show setup view when server is not configured and not connected
  private var shouldShowSetup: Bool {
    if runtimeRegistry.connectedRuntimeCount > 0 { return false }
    if case .notConfigured = serverManager.installState { return true }
    return false
  }

  var body: some View {
    ZStack(alignment: .leading) {
      // Main content (conversation-first)
      mainContent
        .frame(maxWidth: .infinity, maxHeight: .infinity)

      // Left panel overlay
      if showAgentPanel {
        HStack(spacing: 0) {
          AgentListPanel(
            sessions: sessions,
            selectedSessionId: selectedSessionScopedID,
            onSelectSession: { id in
              withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                selectSession(scopedID: id)
              }
            },
            onClose: {
              withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                showAgentPanel = false
              }
            }
          )
          .transition(.move(edge: .leading).combined(with: .opacity))

          // Click-away area
          Color.black.opacity(0.3)
            .onTapGesture {
              withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                showAgentPanel = false
              }
            }
        }
        .transition(.opacity)
      }

      // Quick switcher overlay
      if showQuickSwitcher {
        quickSwitcherOverlay
      }

      // Toast notifications (bottom right)
      VStack {
        Spacer()
        HStack {
          Spacer()
          ToastContainer(
            toastManager: toastManager,
            onSelectSession: { id in
              withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                selectSession(scopedID: id)
              }
            }
          )
        }
      }
    }
    .background(Color.backgroundPrimary)
    .onChange(of: selectedSessionScopedID) { _, newId in
      toastManager.currentSessionId = newId
    }
    .onChange(of: runtimeRegistry.activeEndpointId) { _, _ in
      guard let selectedSessionScopedID else { return }
      guard let selectedRef = unifiedSessionsStore.sessionRef(for: selectedSessionScopedID) else { return }
      if runtimeRegistry.activeEndpointId != selectedRef.endpointId {
        runtimeRegistry.setActiveEndpoint(id: selectedRef.endpointId)
      }
    }
    .onAppear {
      Task { await loadSessions() }
    }
    .onChange(of: runtimeRegistry.connectionStatusByEndpointId) { _, _ in
      Task { await loadSessions() }
    }
    .onChange(of: runtimeRegistry.runtimesByEndpointId.count) { _, _ in
      Task { await loadSessions() }
    }
    .onReceive(NotificationCenter.default.publisher(for: .serverSessionsDidChange)) { _ in
      Task { await loadSessions() }
    }
    .onReceive(NotificationCenter.default.publisher(for: .selectSession)) { notification in
      if let sessionID = notification.userInfo?["sessionId"] as? String {
        let endpointFromNotification: UUID? = {
          if let endpointId = notification.userInfo?["endpointId"] as? UUID {
            return endpointId
          }
          if let endpointString = notification.userInfo?["endpointId"] as? String {
            return UUID(uuidString: endpointString)
          }
          return nil
        }()

        if let ref = unifiedSessionsStore.sessionRef(for: sessionID) {
          selectSession(scopedID: ref.scopedID)
        } else if let endpointId = endpointFromNotification {
          let scopedID = SessionRef(endpointId: endpointId, sessionId: sessionID).scopedID
          selectSession(scopedID: scopedID)
        } else if let activeEndpointId = runtimeRegistry.activeEndpointId {
          let scopedID = SessionRef(endpointId: activeEndpointId, sessionId: sessionID).scopedID
          selectSession(scopedID: scopedID)
        }
      }
    }
    // Keyboard shortcuts via focusable + onKeyPress
    .focusable()
    .onKeyPress(keys: [.escape]) { _ in
      if showQuickSwitcher {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
          showQuickSwitcher = false
        }
        return .handled
      }
      if showAgentPanel {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
          showAgentPanel = false
        }
        return .handled
      }
      return .ignored
    }
    // Use toolbar buttons with keyboard shortcuts
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            selectedSessionScopedID = nil
          }
        } label: {
          Label("Dashboard", systemImage: "square.grid.2x2")
        }
        .keyboardShortcut("0", modifiers: .command)
      }

      ToolbarItem(placement: .primaryAction) {
        Button {
          withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            showAgentPanel.toggle()
          }
        } label: {
          Label("Agents", systemImage: "sidebar.left")
        }
        .keyboardShortcut("1", modifiers: .command)
      }

      ToolbarItem(placement: .primaryAction) {
        Button {
          withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            showQuickSwitcher = true
          }
        } label: {
          Label("Quick Switch", systemImage: "magnifyingglass")
        }
        .keyboardShortcut("k", modifiers: .command)
      }
    }
    .sheet(isPresented: $showNewClaudeSheet) {
      NewClaudeSessionSheet()
    }
    .sheet(isPresented: $showNewCodexSheet) {
      NewCodexSessionSheet()
    }
  }

  // MARK: - Main Content

  private var mainContent: some View {
    Group {
      if shouldShowSetup {
        ServerSetupView()
      } else if let session = selectedSession {
        SessionDetailView(
          session: session,
          onTogglePanel: {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
              showAgentPanel.toggle()
            }
          },
          onOpenSwitcher: {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
              showQuickSwitcher = true
            }
          },
          onGoToDashboard: {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
              selectedSessionScopedID = nil
            }
          }
        )
      } else {
        // Dashboard view when no session selected
        DashboardView(
          sessions: sessions,
          endpointHealth: unifiedSessionsStore.endpointHealth,
          isInitialLoading: isAnyInitialLoading,
          isRefreshingCachedSessions: isAnyRefreshingCachedSessions,
          onSelectSession: { id in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
              selectSession(scopedID: id)
            }
          },
          onOpenQuickSwitcher: {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
              showQuickSwitcher = true
            }
          },
          onOpenPanel: {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
              showAgentPanel = true
            }
          },
          onNewClaude: { showNewClaudeSheet = true },
          onNewCodex: { showNewCodexSheet = true }
        )
      }
    }
  }

  // MARK: - Quick Switcher Overlay

  private var quickSwitcherOverlay: some View {
    ZStack {
      // Backdrop
      Color.black.opacity(0.5)
        .ignoresSafeArea()
        .onTapGesture {
          withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            showQuickSwitcher = false
          }
        }

      // Quick Switcher
      QuickSwitcher(
        sessions: sessions,
        currentSessionId: selectedSessionScopedID,
        onSelect: { id in
          withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            selectSession(scopedID: id)
            showQuickSwitcher = false
          }
        },
        onGoToDashboard: {
          withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            selectedSessionScopedID = nil
            showQuickSwitcher = false
          }
        },
        onClose: {
          withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            showQuickSwitcher = false
          }
        },
        onQuickLaunchClaude: { path in
          creationAppState().createClaudeSession(
            cwd: path,
            model: nil,
            permissionMode: nil,
            allowedTools: [],
            disallowedTools: [],
            effort: nil
          )
        },
        onQuickLaunchCodex: { path in
          let targetState = creationAppState()
          let defaultModel = targetState.codexModels.first(where: { $0.isDefault })?.model
            ?? targetState.codexModels.first?.model ?? ""
          targetState.createSession(
            cwd: path,
            model: defaultModel,
            approvalPolicy: "on-request",
            sandboxMode: "workspace-write"
          )
        },
        onOpenClaudeSheet: {
          showNewClaudeSheet = true
        },
        onOpenCodexSheet: {
          showNewCodexSheet = true
        }
      )
    }
    .transition(.opacity)
  }

  // MARK: - Setup

  private func loadSessions() async {
    let oldWaitingIds = Set(waitingSessions.map(\.scopedID))
    let oldSessions = sessions

    unifiedSessionsStore.refresh()
    sessions = unifiedSessionsStore.sessions

    if let selectedSessionScopedID, !unifiedSessionsStore.containsSession(scopedID: selectedSessionScopedID) {
      self.selectedSessionScopedID = nil
    }

    // Track work status for "agent finished" notifications
    for session in sessions where session.isActive {
      NotificationManager.shared.updateSessionWorkStatus(session: session)
    }

    // Check for new sessions needing attention
    for session in waitingSessions {
      if !oldWaitingIds.contains(session.scopedID) {
        NotificationManager.shared.notifyNeedsAttention(session: session)
      }
    }

    // Clear notifications for sessions no longer needing attention
    for oldId in oldWaitingIds {
      if !waitingSessions.contains(where: { $0.scopedID == oldId }) {
        NotificationManager.shared.resetNotificationState(for: oldId)
      }
    }

    // Check for in-app toast notifications
    toastManager.checkForAttentionChanges(sessions: sessions, previousSessions: oldSessions)

    // Update attention service for cross-session urgency strip
    attentionService.update(sessions: sessions) { session in
      guard let ref = session.sessionRef else { return nil }
      guard let runtime = runtimeRegistry.runtimesByEndpointId[ref.endpointId] else { return nil }
      return runtime.appState.session(ref.sessionId)
    }
  }

  private func selectSession(scopedID: String) {
    guard let ref = unifiedSessionsStore.sessionRef(for: scopedID) else {
      selectedSessionScopedID = nil
      return
    }
    runtimeRegistry.setActiveEndpoint(id: ref.endpointId)
    selectedSessionScopedID = ref.scopedID
  }

  private func creationAppState() -> ServerAppState {
    runtimeRegistry.primaryAppState(fallback: serverState)
  }
}

#Preview {
  ContentView()
    .environment(ServerAppState())
    .environment(ServerRuntimeRegistry.shared)
    .environment(AttentionService())
    .frame(width: 1_000, height: 700)
}
