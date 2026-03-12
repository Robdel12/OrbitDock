import SwiftUI

struct OrbitDockWindowRoot: View {
  @Environment(\.scenePhase) private var scenePhase
  let appRuntime: OrbitDockAppRuntime
  @State private var attentionService: AttentionService
  @State private var router: AppRouter
  @State private var toastManager: ToastManager
  @State private var rootSessionActions: RootSessionActions
  @State private var rootShellStore: RootShellStore
  @State private var rootShellRuntime: RootShellRuntime
  @State private var rootShellEffectsCoordinator: RootShellEffectsCoordinator
  @State private var rootSelectionBridge: RootSelectionBridge
  @State private var windowID = UUID()

  init(appRuntime: OrbitDockAppRuntime) {
    self.appRuntime = appRuntime

    let attentionService = AttentionService()
    let router = AppRouter()
    let toastManager = ToastManager()
    let rootShellStore = RootShellStore()
    _attentionService = State(initialValue: attentionService)
    _router = State(initialValue: router)
    _toastManager = State(initialValue: toastManager)
    _rootSessionActions = State(initialValue: RootSessionActions(runtimeRegistry: appRuntime.runtimeRegistry))
    _rootShellStore = State(initialValue: rootShellStore)
    _rootShellRuntime = State(
      initialValue: RootShellRuntime(
        runtimeRegistry: appRuntime.runtimeRegistry,
        rootShellStore: rootShellStore
      )
    )
    _rootShellEffectsCoordinator = State(
      initialValue: RootShellEffectsCoordinator(
        rootShellStore: rootShellStore,
        attentionService: attentionService,
        notificationManager: appRuntime.notificationManager,
        toastManager: toastManager,
        router: router
      )
    )
    _rootSelectionBridge = State(
      initialValue: RootSelectionBridge(
        runtimeRegistry: appRuntime.runtimeRegistry,
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
      .environment(toastManager)
      .environment(\.rootSessionActions, rootSessionActions)
      .environment(rootShellStore)
      .focusedSceneValue(\.orbitDockRouter, router)
      .preferredColorScheme(.dark)
      .task {
        for await update in rootShellRuntime.updates {
          rootShellEffectsCoordinator.applyRootChange(
            previousMissionControlSessions: update.previousMissionControlSessions,
            currentMissionControlSessions: update.currentMissionControlSessions
          )
        }
      }
      .onAppear {
        appRuntime.externalNavigationCenter.registerWindow(windowID) { command in
          handleExternalCommand(command)
        }
        rootShellEffectsCoordinator.setCurrentSelection(router.selectedScopedID)
        rootShellRuntime.start()
        rootShellRuntime.selectedSessionDidChange(to: router.selectedScopedID)
        rootSelectionBridge.start()
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
      .onChange(of: router.selectedScopedID, initial: true) { _, newId in
        rootShellEffectsCoordinator.setCurrentSelection(newId)
        rootShellRuntime.selectedSessionDidChange(to: newId)
      }
      .onChange(of: appRuntime.runtimeRegistry.connectionStatusByEndpointId) { _, _ in
        rootShellRuntime.runtimeGraphDidChange()
        rootSelectionBridge.runtimeGraphDidChange()
      }
      .onChange(of: appRuntime.runtimeRegistry.runtimesByEndpointId.count) { _, _ in
        rootShellRuntime.runtimeGraphDidChange()
        rootSelectionBridge.runtimeGraphDidChange()
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
          store: rootShellStore,
          fallbackEndpointId: appRuntime.runtimeRegistry.primaryEndpointId ?? appRuntime.runtimeRegistry.activeEndpointId
        )
      }
  }
}
