import SwiftUI

struct OrbitDockWindowRoot: View {
  @Environment(\.scenePhase) private var scenePhase
  let appRuntime: OrbitDockAppRuntime
  @State private var attentionService: AttentionService
  @State private var router: AppRouter
  @State private var toastManager: ToastManager
  @State private var windowSessionCoordinator: WindowSessionCoordinator
  @State private var windowID = UUID()

  init(appRuntime: OrbitDockAppRuntime) {
    self.appRuntime = appRuntime

    let attentionService = AttentionService()
    let router = AppRouter()
    let toastManager = ToastManager()
    _attentionService = State(initialValue: attentionService)
    _router = State(initialValue: router)
    _toastManager = State(initialValue: toastManager)
    _windowSessionCoordinator = State(
      initialValue: WindowSessionCoordinator(
        runtimeRegistry: appRuntime.runtimeRegistry,
        attentionService: attentionService,
        notificationManager: appRuntime.notificationManager,
        toastManager: toastManager,
        router: router
      )
    )
  }

  var body: some View {
    ContentView()
      #if os(macOS)
        .environment(\.serverManager, appRuntime.serverManager)
      #endif
      .environment(appRuntime.runtimeRegistry.activeSessionStore)
      .environment(appRuntime.runtimeRegistry)
      .environment(appRuntime.usageServiceRegistry)
      .environment(appRuntime.notificationManager)
      .environment(attentionService)
      .environment(router)
      .environment(windowSessionCoordinator)
      .focusedSceneValue(\.orbitDockRouter, router)
      .preferredColorScheme(.dark)
      .onAppear {
        appRuntime.externalNavigationCenter.registerWindow(windowID) { command in
          handleExternalCommand(command)
        }
        windowSessionCoordinator.start(currentScopedId: router.selectedScopedID)
        updateWindowFocus(for: scenePhase)
      }
      .onDisappear {
        appRuntime.externalNavigationCenter.unregisterWindow(windowID)
      }
      .onChange(of: scenePhase, initial: true) { _, newPhase in
        updateWindowFocus(for: newPhase)
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
  }

  private func updateWindowFocus(for phase: ScenePhase) {
    let nextFocusedWindowID = AppWindowPlanner.focusedWindowUpdate(
      currentFocusedWindowID: appRuntime.externalNavigationCenter.focusedWindowID,
      windowID: windowID,
      scenePhase: phase
    )
    appRuntime.externalNavigationCenter.updateFocusedWindow(nextFocusedWindowID)
  }

  private func handleExternalCommand(_ command: AppExternalCommand) {
    guard let selection = AppWindowPlanner.externalSelection(
      command: command,
      scenePhase: scenePhase
    ) else { return }

    withAnimation(Motion.standard) {
      windowSessionCoordinator.handleExternalSelection(
        sessionID: selection.sessionID,
        endpointId: selection.endpointID
      )
    }
  }
}
