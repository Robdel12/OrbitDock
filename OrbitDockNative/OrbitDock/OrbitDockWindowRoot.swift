import SwiftUI

struct OrbitDockWindowRoot: View {
  @Environment(\.scenePhase) private var scenePhase
  let appRuntime: OrbitDockAppRuntime
  @State private var attentionService: AttentionService
  @State private var notificationManager: NotificationManager
  @State private var router: AppRouter
  @State private var toastManager: ToastManager
  @State private var windowSessionCoordinator: WindowSessionCoordinator
  @State private var windowID = UUID()

  init(appRuntime: OrbitDockAppRuntime) {
    self.appRuntime = appRuntime

    let attentionService = AttentionService()
    let notificationManager = NotificationManager.shared
    let router = AppRouter()
    let toastManager = ToastManager()
    _attentionService = State(initialValue: attentionService)
    _notificationManager = State(initialValue: notificationManager)
    _router = State(initialValue: router)
    _toastManager = State(initialValue: toastManager)
    _windowSessionCoordinator = State(
      initialValue: WindowSessionCoordinator(
        runtimeRegistry: appRuntime.runtimeRegistry,
        attentionService: attentionService,
        notificationManager: notificationManager,
        toastManager: toastManager,
        router: router
      )
    )
  }

  var body: some View {
    ContentView()
      .environment(appRuntime.runtimeRegistry.activeSessionStore)
      .environment(appRuntime.runtimeRegistry)
      .environment(appRuntime.usageServiceRegistry)
      .environment(attentionService)
      .environment(router)
      .environment(windowSessionCoordinator)
      .focusedSceneValue(\.orbitDockRouter, router)
      .preferredColorScheme(.dark)
      .onAppear {
        windowSessionCoordinator.start(currentScopedId: router.selectedScopedID)
        updateWindowFocus(for: scenePhase)
        consumePendingExternalSelectionIfNeeded()
      }
      .onChange(of: scenePhase, initial: true) { _, newPhase in
        updateWindowFocus(for: newPhase)
        consumePendingExternalSelectionIfNeeded()
      }
      .onChange(of: router.selectedScopedID, initial: true) { _, newId in
        windowSessionCoordinator.selectedSessionDidChange(to: newId)
      }
      .onChange(of: appRuntime.runtimeRegistry.connectionStatusByEndpointId) { _, _ in
        windowSessionCoordinator.runtimeGraphDidChange()
      }
      .onChange(of: appRuntime.runtimeRegistry.runtimesByEndpointId.count) { _, _ in
        windowSessionCoordinator.runtimeGraphDidChange()
      }
      .onChange(of: appRuntime.externalNavigationCenter.pendingSelection?.id) { _, _ in
        consumePendingExternalSelectionIfNeeded()
      }
    #if os(iOS)
      .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
        appRuntime.runtimeRegistry.handleMemoryPressure()
        MarkdownSystemParser.clearCache()
        SyntaxHighlighter.clearCache()
      }
    #endif
  }

  private func updateWindowFocus(for phase: ScenePhase) {
    if phase == .active {
      appRuntime.externalNavigationCenter.updateFocusedWindow(windowID)
    } else if appRuntime.externalNavigationCenter.focusedWindowID == windowID {
      appRuntime.externalNavigationCenter.updateFocusedWindow(nil)
    }
  }

  private func consumePendingExternalSelectionIfNeeded() {
    guard scenePhase == .active else { return }
    guard let request = appRuntime.externalNavigationCenter.selection(for: windowID) else { return }

    withAnimation(Motion.standard) {
      windowSessionCoordinator.handleExternalSelection(
        sessionID: request.sessionId,
        endpointId: request.endpointId
      )
    }
    appRuntime.externalNavigationCenter.markHandled(request.id, by: windowID)
  }
}
