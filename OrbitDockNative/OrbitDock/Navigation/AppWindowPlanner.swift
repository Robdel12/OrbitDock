import SwiftUI

enum AppContentDestination: Equatable {
  case setup
  case session(SessionRef)
  case dashboard
}

enum AppWindowPlanner {
  static func contentDestination(
    connectedRuntimeCount: Int,
    installState: ServerInstallState,
    route: AppRoute
  ) -> AppContentDestination {
    if shouldShowSetup(connectedRuntimeCount: connectedRuntimeCount, installState: installState) {
      return .setup
    }

    switch route {
    case .dashboard:
      return .dashboard
    case let .session(sessionRef):
      return .session(sessionRef)
    }
  }

  static func shouldShowSetup(
    connectedRuntimeCount: Int,
    installState: ServerInstallState
  ) -> Bool {
    if connectedRuntimeCount > 0 { return false }
    if case .notConfigured = installState { return true }
    return false
  }

  static func focusedWindowUpdate(
    currentFocusedWindowID: UUID?,
    windowID: UUID,
    scenePhase: ScenePhase
  ) -> UUID? {
    if scenePhase == .active {
      return windowID
    }

    if currentFocusedWindowID == windowID {
      return nil
    }

    return currentFocusedWindowID
  }

  static func externalSelection(
    command: AppExternalCommand,
    scenePhase: ScenePhase
  ) -> (sessionID: String, endpointID: UUID?)? {
    guard scenePhase == .active else { return nil }

    switch command {
    case let .selectSession(sessionID, endpointID):
      return (sessionID, endpointID)
    }
  }
}
