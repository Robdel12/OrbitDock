//
//  ContentView.swift
//  OrbitDock
//
//  Created by Robert DeLuca on 1/30/26.
//

import SwiftUI

enum ServerSetupVisibility {
  static func shouldShowSetup(
    connectedRuntimeCount: Int,
    installState: ServerInstallState
  ) -> Bool {
    if connectedRuntimeCount > 0 { return false }
    if case .notConfigured = installState { return true }
    return false
  }
}

struct ContentView: View {
  @Environment(ServerAppState.self) private var serverState
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry
  @Environment(AttentionService.self) private var attentionService
  @Environment(AppRouter.self) private var router
  @StateObject private var serverManager = ServerManager.shared
  @State private var unifiedSessionsStore = UnifiedSessionsStore()
  @State private var sessions: [Session] = []
  @StateObject private var toastManager = ToastManager.shared

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
    ServerSetupVisibility.shouldShowSetup(
      connectedRuntimeCount: runtimeRegistry.connectedRuntimeCount,
      installState: serverManager.installState
    )
  }

  var body: some View {
    @Bindable var router = router

    ZStack {
      mainContent
        .frame(maxWidth: .infinity, maxHeight: .infinity)

      // Quick switcher overlay
      if router.showQuickSwitcher {
        quickSwitcherOverlay
      }

      // Toast notifications (top right, under header)
      VStack {
        HStack {
          Spacer()
          ToastContainer(
            toastManager: toastManager
          )
        }
        Spacer()
      }
    }
    .background(Color.backgroundPrimary)
    .onChange(of: router.selectedScopedID) { _, newId in
      toastManager.currentSessionId = newId
    }
    .onChange(of: runtimeRegistry.activeEndpointId) { _, _ in
      guard let ref = router.selectedSessionRef else { return }
      if runtimeRegistry.activeEndpointId != ref.endpointId {
        runtimeRegistry.setActiveEndpoint(id: ref.endpointId)
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

        withAnimation(Motion.standard) {
          router.handleExternalNavigation(
            sessionID: sessionID,
            endpointId: endpointFromNotification,
            store: unifiedSessionsStore,
            runtimeRegistry: runtimeRegistry
          )
        }
      }
    }
    // Keyboard shortcuts
    .focusable()
    .onKeyPress(keys: [.escape]) { _ in
      if router.showQuickSwitcher {
        withAnimation(Motion.standard) {
          router.closeQuickSwitcher()
        }
        return .handled
      }
      return .ignored
    }
    #if os(macOS)
    .toolbar(.hidden)
    #endif
    .sheet(isPresented: $router.showNewClaudeSheet) {
      NewClaudeSessionSheet()
      #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
      #endif
    }
    .sheet(isPresented: $router.showNewCodexSheet) {
      NewCodexSessionSheet()
      #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
      #endif
    }
  }

  // MARK: - Main Content

  private var mainContent: some View {
    Group {
      if shouldShowSetup {
        ServerSetupView()
      } else if let ref = router.selectedSessionRef {
        SessionDetailView(
          sessionId: ref.sessionId,
          endpointId: ref.endpointId
        )
        .id(ref.scopedID)
      } else {
        // Dashboard view when no session selected
        DashboardView(
          sessions: sessions,
          endpointHealth: unifiedSessionsStore.endpointHealth,
          isInitialLoading: isAnyInitialLoading,
          isRefreshingCachedSessions: isAnyRefreshingCachedSessions
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
          withAnimation(Motion.standard) {
            router.closeQuickSwitcher()
          }
        }

      // Quick Switcher
      QuickSwitcher(
        sessions: sessions,
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

    if let selectedScopedID = router.selectedScopedID,
       !unifiedSessionsStore.containsSession(scopedID: selectedScopedID)
    {
      router.goToDashboard()
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

  private func creationAppState() -> ServerAppState {
    runtimeRegistry.primaryAppState(fallback: serverState)
  }
}

#Preview {
  ContentView()
    .environment(ServerAppState())
    .environment(ServerRuntimeRegistry.shared)
    .environment(AttentionService())
    .environment(AppRouter())
    .frame(width: 1_000, height: 700)
}
