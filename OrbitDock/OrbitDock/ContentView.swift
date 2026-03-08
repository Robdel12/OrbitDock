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

enum MissionControlNotificationSessions {
  static func merge(previousSessions: [Session], currentSessions: [Session]) -> [Session] {
    var mergedByScopedID: [String: Session] = [:]
    var orderedScopedIDs: [String] = []

    for session in currentSessions {
      let scopedID = session.scopedID
      if mergedByScopedID[scopedID] == nil {
        orderedScopedIDs.append(scopedID)
      }
      mergedByScopedID[scopedID] = session
    }

    for session in previousSessions {
      let scopedID = session.scopedID
      guard mergedByScopedID[scopedID] == nil else { continue }
      mergedByScopedID[scopedID] = session
      orderedScopedIDs.append(scopedID)
    }

    return orderedScopedIDs.compactMap { mergedByScopedID[$0] }
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

  var missionControlSessions: [Session] {
    sessions.filter(\.showsInMissionControl)
  }

  var missionControlAttentionSessions: [Session] {
    missionControlSessions.filter(\.needsAttention)
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

  private var newSessionSheetBinding: Binding<Bool> {
    Binding(
      get: { router.showNewSessionSheet },
      set: { isPresented in
        if isPresented {
          router.showNewSessionSheet = true
        } else {
          router.closeNewSessionSheet()
        }
      }
    )
  }

  var body: some View {
    AnyView(contentBody)
  }

  private var contentBody: some View {
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
    .onChange(of: router.selectedScopedID, initial: true, updateToastSessionSelection)
    .onChange(of: runtimeRegistry.activeEndpointId, synchronizeActiveEndpoint)
    .onAppear {
      Task { await loadSessions() }
    }
    .onChange(of: runtimeRegistry.connectionStatusByEndpointId, reloadSessions)
    .onChange(of: runtimeRegistry.runtimesByEndpointId.count, reloadSessions)
    .onReceive(NotificationCenter.default.publisher(for: .serverSessionsDidChange), perform: handleSessionsDidChange)
    .onReceive(NotificationCenter.default.publisher(for: .selectSession), perform: handleSelectSessionNotification)
    // Keyboard shortcuts
    .focusable()
    .onKeyPress(keys: [.escape]) { keyPress in
      handleEscapeKey(keyPress)
    }
    #if os(macOS)
    .toolbar(.hidden)
    #endif
    .sheet(isPresented: newSessionSheetBinding) {
      newSessionSheet
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

  @ViewBuilder
  private var newSessionSheet: some View {
    NewSessionSheet(
      provider: router.newSessionProvider,
      continuation: router.newSessionContinuation
    )
    #if os(iOS)
      .presentationDetents([.large])
      .presentationDragIndicator(.visible)
    #endif
  }

  // MARK: - Setup

  private func loadSessions() async {
    let previousMissionControlSessions = missionControlSessions
    let oldWaitingIds = Set(missionControlAttentionSessions.map(\.scopedID))
    let oldSessions = sessions

    unifiedSessionsStore.refresh()
    sessions = unifiedSessionsStore.sessions

    if let selectedScopedID = router.selectedScopedID,
       !unifiedSessionsStore.containsSession(scopedID: selectedScopedID)
    {
      router.goToDashboard()
    }

    // Track work status for "agent finished" notifications. Feed both current
    // and previously-live sessions so offline transitions clear out correctly.
    let notificationSessions = MissionControlNotificationSessions.merge(
      previousSessions: previousMissionControlSessions,
      currentSessions: sessions
    )

    for session in notificationSessions {
      NotificationManager.shared.updateSessionWorkStatus(session: session)
    }

    // Check for new sessions needing attention
    for session in missionControlAttentionSessions {
      if !oldWaitingIds.contains(session.scopedID) {
        NotificationManager.shared.notifyNeedsAttention(session: session)
      }
    }

    // Clear notifications for sessions no longer needing attention
    for oldId in oldWaitingIds {
      if !missionControlAttentionSessions.contains(where: { $0.scopedID == oldId }) {
        NotificationManager.shared.resetNotificationState(for: oldId)
      }
    }

    // Check for in-app toast notifications
    toastManager.checkForAttentionChanges(
      sessions: missionControlSessions,
      previousSessions: oldSessions.filter(\.showsInMissionControl)
    )

    // Update attention service for cross-session urgency strip
    attentionService.update(sessions: missionControlSessions) { session in
      guard let ref = session.sessionRef else { return nil }
      guard let runtime = runtimeRegistry.runtimesByEndpointId[ref.endpointId] else { return nil }
      return runtime.appState.session(ref.sessionId)
    }
  }

  private func creationAppState() -> ServerAppState {
    runtimeRegistry.primaryAppState(fallback: serverState)
  }

  private func updateToastSessionSelection(_: String?, _ newId: String?) {
    toastManager.currentSessionId = newId
  }

  private func synchronizeActiveEndpoint(_: UUID?, _: UUID?) {
    guard let ref = router.selectedSessionRef else { return }
    if runtimeRegistry.activeEndpointId != ref.endpointId {
      runtimeRegistry.setActiveEndpoint(id: ref.endpointId)
    }
  }

  private func reloadSessions<T>(_: T, _: T) {
    Task { await loadSessions() }
  }

  private func handleSessionsDidChange(_: Notification) {
    Task { await loadSessions() }
  }

  private func handleSelectSessionNotification(_ notification: Notification) {
    guard let sessionID = notification.userInfo?["sessionId"] as? String else { return }

    withAnimation(Motion.standard) {
      router.handleExternalNavigation(
        sessionID: sessionID,
        endpointId: endpointId(from: notification),
        store: unifiedSessionsStore,
        runtimeRegistry: runtimeRegistry
      )
    }
  }

  private func endpointId(from notification: Notification) -> UUID? {
    if let endpointId = notification.userInfo?["endpointId"] as? UUID {
      return endpointId
    }
    if let endpointString = notification.userInfo?["endpointId"] as? String {
      return UUID(uuidString: endpointString)
    }
    return nil
  }

  private func handleEscapeKey(_: KeyPress) -> KeyPress.Result {
    guard router.showQuickSwitcher else { return .ignored }
    withAnimation(Motion.standard) {
      router.closeQuickSwitcher()
    }
    return .handled
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
