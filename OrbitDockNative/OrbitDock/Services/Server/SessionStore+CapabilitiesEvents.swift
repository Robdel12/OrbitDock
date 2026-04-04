import Foundation

@MainActor
extension SessionStore {
  func routeCapabilitiesEvent(_ event: ServerEvent) -> Bool {
    switch event {
      case let .skillsList(sessionId, _, _):
        notifySessionChanged(sessionId)
        return true
      case .skillsUpdateAvailable(_):
        return true
      case let .mcpToolsList(sessionId, _, _, _, _):
        notifySessionChanged(sessionId)
        return true
      case let .mcpStartupUpdate(sessionId, _, _):
        notifySessionChanged(sessionId)
        return true
      case let .mcpStartupComplete(sessionId, _, _, _):
        notifySessionChanged(sessionId)
        return true
      case let .claudeCapabilities(sessionId, _, _, _, _):
        notifySessionChanged(sessionId)
        return true
      default:
        return false
    }
  }
}
