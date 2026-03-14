import SwiftUI

struct OrbitDockWindowRoot: View {
  @Environment(\.scenePhase) private var scenePhase
  let appRuntime: OrbitDockAppRuntime
  @State private var appStore: AppStore
  @State private var router: AppRouter
  @State private var toastManager: ToastManager
  @State private var windowID = UUID()

  init(appRuntime: OrbitDockAppRuntime) {
    self.appRuntime = appRuntime

    let router = AppRouter()
    let toastManager = ToastManager()
    let appStore = AppStore(connection: appRuntime.runtimeRegistry.primaryConnection)
    appStore.router = router

    _appStore = State(initialValue: appStore)
    _router = State(initialValue: router)
    _toastManager = State(initialValue: toastManager)
  }

  var body: some View {
    ContentView()
      #if os(macOS)
        .environment(\.serverManager, appRuntime.serverManager)
      #endif
      .environment(appRuntime.runtimeRegistry)
      .environment(appRuntime.usageServiceRegistry)
      .environment(appRuntime.notificationManager)
      .environment(router)
      .environment(toastManager)
      .environment(appStore)
      .focusedSceneValue(\.orbitDockRouter, router)
      .preferredColorScheme(.dark)
      .task {
        appStore.start()
      }
      .onAppear {
        print("[OrbitDock][WindowRoot] onAppear windowID=\(windowID.uuidString)")
        appRuntime.externalNavigationCenter.registerWindow(windowID) { command in
          handleExternalCommand(command)
        }
        updateWindowFocus(for: scenePhase)
      }
      .onDisappear {
        appRuntime.externalNavigationCenter.unregisterWindow(windowID)
      }
      .onChange(of: scenePhase, initial: true) { oldPhase, newPhase in
        updateWindowFocus(for: newPhase)
        if oldPhase != .active, newPhase == .active {
          appRuntime.runtimeRegistry.reconnectAllIfNeeded()
        }
      }
      .onChange(of: router.route, initial: true) { _, newRoute in
        print("[OrbitDock][WindowRoot] route changed to \(newRoute)")
        appStore.setCurrentSelection(router.selectedSessionRef)
      }
      .onChange(of: appRuntime.runtimeRegistry.connectionStatusByEndpointId) { _, _ in
        appStore.runtimeGraphDidChange()
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
      if let ref = appStore.resolveSessionRef(sessionID: selection.sessionID) {
        router.selectSession(ref)
      }
    }
  }
}
