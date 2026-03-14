import SwiftUI

struct OrbitDockWindowRoot: View {
  @Environment(\.scenePhase) private var scenePhase
  let appRuntime: OrbitDockAppRuntime
  @State private var appStore: AppStore
  @State private var router: AppRouter
  @State private var toastManager: ToastManager
  @State private var rootSessionActions: RootSessionActions
  @State private var windowID = UUID()

  init(appRuntime: OrbitDockAppRuntime) {
    self.appRuntime = appRuntime

    let attentionService = AttentionService()
    let router = AppRouter()
    let toastManager = ToastManager()
    let appStore = AppStore(
      runtimeRegistry: appRuntime.runtimeRegistry,
      attentionService: attentionService,
      notificationManager: appRuntime.notificationManager,
      toastManager: toastManager
    )
    appStore.router = router

    _appStore = State(initialValue: appStore)
    _router = State(initialValue: router)
    _toastManager = State(initialValue: toastManager)
    _rootSessionActions = State(initialValue: RootSessionActions(runtimeRegistry: appRuntime.runtimeRegistry))
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
      .environment(\.rootSessionActions, rootSessionActions)
      .environment(appStore)
      .focusedSceneValue(\.orbitDockRouter, router)
      .preferredColorScheme(.dark)
      .onAppear {
        let message = "onAppear windowID=\(windowID.uuidString) router=\(String(describing: ObjectIdentifier(router)))"
        print("[OrbitDock][WindowRoot] \(message)")
        NSLog("[OrbitDock][WindowRoot] %@", message)
        appRuntime.externalNavigationCenter.registerWindow(windowID) { command in
          handleExternalCommand(command)
        }
        appStore.setCurrentSelection(router.selectedSessionRef)
        appStore.start()
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
        let message =
          "route changed to \(String(describing: newRoute)) windowID=\(windowID.uuidString) router=\(String(describing: ObjectIdentifier(router)))"
        print("[OrbitDock][WindowRoot] \(message)")
        NSLog("[OrbitDock][WindowRoot] %@", message)
        appStore.setCurrentSelection(router.selectedSessionRef)
      }
      .onChange(of: appRuntime.runtimeRegistry.connectionStatusByEndpointId) { _, _ in
        appStore.runtimeGraphDidChange()
      }
      .onChange(of: appRuntime.runtimeRegistry.runtimesByEndpointId.count) { _, _ in
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
      router.handleExternalNavigation(
        sessionID: selection.sessionID,
        endpointId: selection.endpointID,
        store: appStore,
        fallbackEndpointId: appRuntime.runtimeRegistry.primaryEndpointId ?? appRuntime.runtimeRegistry.activeEndpointId
      )
    }
  }
}
