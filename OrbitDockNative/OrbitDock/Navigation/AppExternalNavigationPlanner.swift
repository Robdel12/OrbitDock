import Foundation

@MainActor
enum AppExternalNavigationPlanner {
  static func resolvedSessionRef(
    sessionID: String,
    explicitEndpointId: UUID?,
    selectedEndpointId: UUID?,
    fallbackEndpointId: UUID?,
    rootShellStore: RootShellStore
  ) -> SessionRef? {
    if let ref = rootShellStore.sessionRef(for: sessionID) {
      return ref
    }

    if let explicitEndpointId {
      return SessionRef(endpointId: explicitEndpointId, sessionId: sessionID)
    }

    guard let endpointId = selectedEndpointId ?? fallbackEndpointId else {
      return nil
    }

    return SessionRef(endpointId: endpointId, sessionId: sessionID)
  }
}
