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
  @Environment(SessionStore.self) private var serverState
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry
  @Environment(AppRouter.self) private var router
  @Environment(WindowSessionCoordinator.self) private var windowSessionCoordinator
  #if os(macOS)
    @Environment(\.serverManager) private var serverManager
  #endif

  private var isAnyRefreshingCachedSessions: Bool {
    false
  }

  private var currentInstallState: ServerInstallState {
    #if os(macOS)
      serverManager.installState
    #else
      .remote
    #endif
  }

  /// Show setup view when server is not configured and not connected
  private var shouldShowSetup: Bool {
    ServerSetupVisibility.shouldShowSetup(
      connectedRuntimeCount: runtimeRegistry.connectedRuntimeCount,
      installState: currentInstallState
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
    contentBody
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
            toastManager: windowSessionCoordinator.toastManager
          )
        }
        Spacer()
      }
    }
    .background(Color.backgroundPrimary)
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
          sessions: windowSessionCoordinator.sessions,
          endpointHealth: windowSessionCoordinator.endpointHealth,
          isInitialLoading: windowSessionCoordinator.isAnyInitialLoading,
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
        sessions: windowSessionCoordinator.sessions,
        onQuickLaunchClaude: { path in
          Task {
            try? await windowSessionCoordinator.creationStore(fallback: serverState).createSession(
              SessionsClient.CreateSessionRequest(provider: "claude", cwd: path)
            )
          }
        },
        onQuickLaunchCodex: { path in
          let targetState = windowSessionCoordinator.creationStore(fallback: serverState)
          let defaultModel = targetState.codexModels.first(where: { $0.isDefault })?.model
            ?? targetState.codexModels.first?.model ?? ""
          Task {
            try? await targetState.createSession(
              SessionsClient.CreateSessionRequest(
                provider: "codex",
                cwd: path,
                model: defaultModel,
                approvalPolicy: "on-request",
                sandboxMode: "workspace-write"
              )
            )
          }
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

  private func handleEscapeKey(_: KeyPress) -> KeyPress.Result {
    guard router.showQuickSwitcher else { return .ignored }
    withAnimation(Motion.standard) {
      router.closeQuickSwitcher()
    }
    return .handled
  }
}

#Preview {
  let preview = PreviewRuntime(scenario: .dashboard)
  preview.inject(ContentView())
    .frame(width: 1_000, height: 700)
}
