import Foundation
import SwiftUI

@MainActor
final class RootSessionActions {
  enum ActionError: Error {
    case endpointUnavailable(UUID)
  }

  private let runtimeRegistry: ServerRuntimeRegistry

  init(runtimeRegistry: ServerRuntimeRegistry) {
    self.runtimeRegistry = runtimeRegistry
  }

  func endSession(_ session: RootSessionNode) async throws {
    try await endSession(session.sessionRef)
  }

  func endSession(_ sessionRef: SessionRef) async throws {
    guard let endpointStore = runtimeRegistry.endpointStoreIfAvailable(for: sessionRef.endpointId) else {
      throw ActionError.endpointUnavailable(sessionRef.endpointId)
    }
    _ = try await endpointStore.session(sessionRef.sessionId).api.endSession()
  }

  func renameSession(_ session: RootSessionNode, name: String?) async throws {
    guard let endpointStore = runtimeRegistry.endpointStoreIfAvailable(for: session.endpointId) else {
      throw ActionError.endpointUnavailable(session.endpointId)
    }
    _ = try await endpointStore.session(session.sessionId).api.renameSession(name: name)
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
