//
//  ContentView.swift
//  OrbitDock
//
//  Created by Robert DeLuca on 1/30/26.
//

import SwiftUI

struct ContentView: View {
  @Environment(ServerAppState.self) private var serverState
  @Environment(AttentionService.self) private var attentionService
  @StateObject private var serverManager = ServerManager.shared
  @State private var sessions: [Session] = []
  @State private var selectedSessionId: String?
  @StateObject private var toastManager = ToastManager.shared

  // Panel state
  @State private var showAgentPanel = false
  @State private var showQuickSwitcher = false

  /// Resolve ID to fresh session object from current sessions array
  private var selectedSession: Session? {
    guard let id = selectedSessionId else { return nil }
    return sessions.first { $0.id == id }
  }

  var workingSessions: [Session] {
    sessions.filter { $0.isActive && $0.workStatus == .working }
  }

  var waitingSessions: [Session] {
    sessions.filter(\.needsAttention)
  }

  /// Show setup view when server is not configured and not connected
  private var shouldShowSetup: Bool {
    if case .connected = ServerConnection.shared.status { return false }
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
            selectedSessionId: selectedSessionId,
            onSelectSession: { id in
              withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                selectedSessionId = id
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
                selectedSessionId = id
              }
            }
          )
        }
      }
    }
    .background(Color.backgroundPrimary)
    .onChange(of: selectedSessionId) { _, newId in
      toastManager.currentSessionId = newId
    }
    .onAppear {
      Task { await loadSessions() }
    }
    .onChange(of: serverState.sessions) { _, _ in
      Task { await loadSessions() }
    }
    .onReceive(NotificationCenter.default.publisher(for: .selectSession)) { notification in
      if let sessionId = notification.userInfo?["sessionId"] as? String {
        selectedSessionId = sessionId
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
            selectedSessionId = nil
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
              selectedSessionId = nil
            }
          }
        )
      } else {
        // Dashboard view when no session selected
        DashboardView(
          sessions: sessions,
          isInitialLoading: serverState.isLoadingInitialSessions,
          isRefreshingCachedSessions: serverState.isRefreshingCachedSessions,
          onSelectSession: { id in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
              selectedSessionId = id
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
          }
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
        currentSessionId: selectedSessionId,
        onSelect: { id in
          withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            selectedSessionId = id
            showQuickSwitcher = false
          }
        },
        onGoToDashboard: {
          withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            selectedSessionId = nil
            showQuickSwitcher = false
          }
        },
        onClose: {
          withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            showQuickSwitcher = false
          }
        }
      )
    }
    .transition(.opacity)
  }

  // MARK: - Setup

  private func loadSessions() async {
    let oldWaitingIds = Set(waitingSessions.map(\.id))
    let oldSessions = sessions

    // Rust server is the runtime source of truth for session list identity/state.
    // Avoid merging DB rows in-app to prevent direct/passive shadow drift on rebuild.
    sessions = serverState.sessions

    // Track work status for "agent finished" notifications
    for session in sessions where session.isActive {
      NotificationManager.shared.updateSessionWorkStatus(session: session)
    }

    // Check for new sessions needing attention
    for session in waitingSessions {
      if !oldWaitingIds.contains(session.id) {
        NotificationManager.shared.notifyNeedsAttention(session: session)
      }
    }

    // Clear notifications for sessions no longer needing attention
    for oldId in oldWaitingIds {
      if !waitingSessions.contains(where: { $0.id == oldId }) {
        NotificationManager.shared.resetNotificationState(for: oldId)
      }
    }

    // Check for in-app toast notifications
    toastManager.checkForAttentionChanges(sessions: sessions, previousSessions: oldSessions)

    // Update attention service for cross-session urgency strip
    attentionService.update(sessions: sessions, sessionObservable: serverState.session)
  }
}

#Preview {
  ContentView()
    .environment(ServerAppState())
    .environment(AttentionService())
    .frame(width: 1_000, height: 700)
}
