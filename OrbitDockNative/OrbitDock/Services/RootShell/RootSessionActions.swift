import Foundation
import SwiftUI

@MainActor
final class RootSessionActions {
  private let runtimeRegistry: ServerRuntimeRegistry

  init(runtimeRegistry: ServerRuntimeRegistry) {
    self.runtimeRegistry = runtimeRegistry
  }

  func endSession(_ session: RootSessionNode) async throws {
    try await sessionStore(for: session).endSession(session.sessionId)
  }

  func renameSession(_ session: RootSessionNode, name: String?) async throws {
    try await sessionStore(for: session).renameSession(session.sessionId, name: name)
  }

  private func sessionStore(for session: RootSessionNode) -> SessionStore {
    runtimeRegistry.sessionStore(
      for: session.endpointId,
      fallback: runtimeRegistry.activeSessionStore
    )
  }
}

private struct RootSessionActionsEnvironmentKey: EnvironmentKey {
  @MainActor static let defaultValue = RootSessionActions(
    runtimeRegistry: ServerRuntimeRegistry(
      endpointsProvider: { [] },
      runtimeFactory: { _ in fatalError("No runtime available in default RootSessionActions environment") },
      shouldBootstrapFromSettings: false
    )
  )
}

extension EnvironmentValues {
  var rootSessionActions: RootSessionActions {
    get { self[RootSessionActionsEnvironmentKey.self] }
    set { self[RootSessionActionsEnvironmentKey.self] = newValue }
  }
}
