//
//  ContentView.swift
//  OrbitDock
//
//  Created by Robert DeLuca on 1/30/26.
//

import SwiftUI

struct ContentView: View {
  @Environment(ServerRuntimeRegistry.self) private var runtimeRegistry
  @Environment(AppRouter.self) private var router
  @Environment(ToastManager.self) private var toastManager
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
    AppWindowPlanner.shouldShowSetup(
      connectedRuntimeCount: runtimeRegistry.connectedRuntimeCount,
      installState: currentInstallState
    )
  }

  private var contentDestination: AppContentDestination {
    AppWindowPlanner.contentDestination(
      connectedRuntimeCount: runtimeRegistry.connectedRuntimeCount,
      installState: currentInstallState,
      route: router.route
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
            toastManager: toastManager
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
      switch contentDestination {
      case .setup:
        ServerSetupView()
          .onAppear {
            
          }
      case let .session(ref):
        SessionDetailView(
          sessionId: ref.sessionId,
          endpointId: ref.endpointId
        )
        .environment(detailSessionStore(for: ref.endpointId))
        .id(ref.scopedID)
      case .dashboard:
        dashboardView
          .onAppear {
          }
      }
    }
  }

  private var dashboardView: some View {
    DashboardView(
      isInitialLoading: runtimeRegistry.runtimes
        .filter(\.endpoint.isEnabled)
        .contains { !$0.connection.hasReceivedInitialSessionsList },
      isRefreshingCachedSessions: isAnyRefreshingCachedSessions
    )
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
        onQuickLaunchClaude: { path in
          Task {
            try? await creationStore().createSession(
              SessionsClient.CreateSessionRequest(provider: "claude", cwd: path)
            )
          }
        },
        onQuickLaunchCodex: { path in
          let targetState = creationStore()
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
    .environment(creationStore())
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

  private func creationStore() -> SessionStore {
    let fallbackStore = runtimeRegistry.activeSessionStore
    let preferredEndpointId = router.selectedEndpointId ?? router.selectedSessionRef?.endpointId
    let primaryStore = runtimeRegistry.primarySessionStore(fallback: fallbackStore)
    return runtimeRegistry.sessionStore(for: preferredEndpointId, fallback: primaryStore)
  }

  private func detailSessionStore(for endpointId: UUID) -> SessionStore {
    let fallbackStore = runtimeRegistry.activeSessionStore
    return runtimeRegistry.sessionStore(for: endpointId, fallback: fallbackStore)
  }
}

#Preview {
  let preview = PreviewRuntime(scenario: .dashboard)
  preview.inject(ContentView())
    .frame(width: 1_000, height: 700)
}
