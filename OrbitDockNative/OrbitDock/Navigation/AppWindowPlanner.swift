import SwiftUI

enum AppContentDestination: Equatable {
  case setup
  case session(SessionRef)
  case mission(MissionRef)
  case terminal(terminalId: String)
  case dashboard
}

enum AppWindowPlanner {
  static func contentDestination(
    connectedRuntimeCount: Int,
    hasEndpoints: Bool = true,
    selectedSessionRef: SessionRef?
  ) -> AppContentDestination {
    if shouldShowSetup(
      connectedRuntimeCount: connectedRuntimeCount,
      hasEndpoints: hasEndpoints
    ) {
      return .setup
    }

    if let selectedSessionRef {
      return .session(selectedSessionRef)
    }

    return .dashboard
  }

  static func contentDestination(
    connectedRuntimeCount: Int,
    hasEndpoints: Bool = true,
    route: AppRoute
  ) -> AppContentDestination {
    if shouldShowSetup(
      connectedRuntimeCount: connectedRuntimeCount,
      hasEndpoints: hasEndpoints
    ) {
      return .setup
    }

    switch route {
      case .dashboard:
        return .dashboard
      case let .session(ref):
        return .session(ref)
      case let .mission(ref):
        return .mission(ref)
      case let .terminal(terminalId):
        return .terminal(terminalId: terminalId)
    }
  }

  static func shouldShowSetup(
    connectedRuntimeCount: Int,
    hasEndpoints: Bool = true
  ) -> Bool {
    if connectedRuntimeCount > 0 { return false }
    if !hasEndpoints { return true }
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
