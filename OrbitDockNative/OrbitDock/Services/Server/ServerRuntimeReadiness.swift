import Foundation

struct ServerRuntimeReadiness: Equatable, Sendable {
  let transportReady: Bool
  let serverRoleReady: Bool

  static let offline = ServerRuntimeReadiness(
    transportReady: false,
    serverRoleReady: false
  )

  static func derive(connectionStatus: ConnectionStatus) -> ServerRuntimeReadiness {
    let transportReady = connectionStatus == .connected
    let serverRoleReady = transportReady
    return ServerRuntimeReadiness(
      transportReady: transportReady,
      serverRoleReady: serverRoleReady
    )
  }
}
