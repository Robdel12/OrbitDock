import Foundation

enum ServerSessionListRefresh {
  static func endpointIDsToRefresh(runtimes: [ServerRuntime]) -> [UUID] {
    runtimes
      .filter { $0.endpoint.isEnabled }
      .map(\.endpoint.id)
  }
}

@MainActor
extension ServerRuntimeRegistry {
  @discardableResult
  func refreshEnabledSessionLists() -> [UUID] {
    let endpointIDs = ServerSessionListRefresh.endpointIDsToRefresh(runtimes: runtimes)
    for endpointID in endpointIDs {
      runtimesByEndpointId[endpointID]?.sessionStore.refreshSessionsList()
    }
    return endpointIDs
  }
}
