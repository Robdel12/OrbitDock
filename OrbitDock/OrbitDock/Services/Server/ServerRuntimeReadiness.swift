import Foundation

struct ServerRuntimeReadiness: Equatable, Sendable {
  let transportReady: Bool
  let controlPlaneReady: Bool
  let queryReady: Bool

  static let offline = ServerRuntimeReadiness(
    transportReady: false,
    controlPlaneReady: false,
    queryReady: false
  )

  static func derive(
    connectionStatus: ConnectionStatus,
    hasReceivedInitialSessionsList: Bool
  ) -> ServerRuntimeReadiness {
    let transportReady = connectionStatus == .connected
    let controlPlaneReady = transportReady && hasReceivedInitialSessionsList
    let queryReady = controlPlaneReady
    return ServerRuntimeReadiness(
      transportReady: transportReady,
      controlPlaneReady: controlPlaneReady,
      queryReady: queryReady
    )
  }
}
