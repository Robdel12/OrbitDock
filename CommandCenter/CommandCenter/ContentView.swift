//
//  ContentView.swift
//  OrbitDock
//
//  Created by Robert DeLuca on 1/30/26.
//

import Combine
import SwiftUI

struct ContentView: View {
  @Environment(SessionStore.self) private var database
  @Environment(ServerAppState.self) private var serverState
  @State private var sessions: [Session] = []
  @State private var selectedSessionId: String?
  @State private var eventSubscription: AnyCancellable?
  @StateObject private var toastManager = ToastManager.shared

  // Panel state
  @State private var showAgentPanel = false
  @State private var showQuickSwitcher = false
  @State private var showInbox = false

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

      // Inbox overlay
      if showInbox {
        inboxOverlay
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
      setupEventSubscription()
    }
    .onDisappear {
      eventSubscription?.cancel()
      eventSubscription = nil
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
      if showInbox {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
          showInbox = false
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
      if let session = selectedSession {
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
          },
          onOpenInbox: {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
              showInbox = true
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
        onNavigateToQuest: { questId in
          withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            selectedSessionId = nil
            showQuickSwitcher = false
          }
          // Post notification for DashboardView to navigate to quest
          NotificationCenter.default.post(
            name: .navigateToQuest,
            object: nil,
            userInfo: ["questId": questId]
          )
        },
        onOpenInbox: {
          withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            showQuickSwitcher = false
            showInbox = true
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

  // MARK: - Inbox Overlay

  private var inboxOverlay: some View {
    ZStack {
      // Backdrop
      Color.black.opacity(0.5)
        .ignoresSafeArea()
        .onTapGesture {
          withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
            showInbox = false
          }
        }

      // Inbox panel
      InboxView(onClose: {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
          showInbox = false
        }
      })
      .frame(width: 500, height: 600)
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      .shadow(color: .black.opacity(0.5), radius: 40, x: 0, y: 20)
    }
    .transition(.opacity)
  }

  // MARK: - Setup

  private func setupEventSubscription() {
    eventSubscription = EventBus.shared.sessionUpdated
      .receive(on: DispatchQueue.main)
      .sink { _ in
        Task { @MainActor in
          await loadSessions()
        }
        NotificationCenter.default.post(name: Notification.Name("DatabaseChanged"), object: nil)
      }

    database.onDatabaseChanged = {
      // File monitor detected change - trigger EventBus which handles refresh
      EventBus.shared.notifyDatabaseChanged()
    }
  }

  private func loadSessions() async {
    let oldWaitingIds = Set(waitingSessions.map(\.id))
    let oldSessions = sessions
    let previousSelectionId = selectedSessionId

    // Rust server is the runtime source of truth for session list identity/state.
    // Avoid merging DB rows in-app to prevent direct/passive shadow drift on rebuild.
    sessions = serverState.sessions

    // If selection is a passive Codex shadow row, remap to its direct session.
    if let selectedId = previousSelectionId {
      if let selected = sessions.first(where: { $0.id == selectedId }) {
        if selected.provider == .codex, !selected.isDirectCodex,
           let direct = sessions.first(where: { $0.isDirectCodex && $0.codexThreadId == selected.id })
        {
          selectedSessionId = direct.id
        }
      } else if let previous = oldSessions.first(where: { $0.id == selectedId }),
                previous.provider == .codex,
                let direct = sessions.first(where: { $0.isDirectCodex && ($0.codexThreadId == previous.id || $0.projectPath == previous.projectPath) })
      {
        selectedSessionId = direct.id
      }
    }

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
  }
}

#Preview {
  ContentView()
    .environment(SessionStore.shared)
    .environment(ServerAppState())
    .frame(width: 1_000, height: 700)
}
