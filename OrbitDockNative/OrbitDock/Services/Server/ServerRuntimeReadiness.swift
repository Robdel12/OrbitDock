import Foundation

struct ServerRuntimeReadiness: Equatable, Sendable {
  let transportReady: Bool
  let controlPlaneReady: Bool
  let dashboardReady: Bool
  let missionsReady: Bool

  static let offline = ServerRuntimeReadiness(
    transportReady: false,
    controlPlaneReady: false,
    dashboardReady: false,
    missionsReady: false
  )

  static func derive(
    connectionStatus: ConnectionStatus,
    hasReceivedInitialDashboardSnapshot: Bool,
    hasReceivedInitialMissionsSnapshot: Bool
  ) -> ServerRuntimeReadiness {
    // HTTP bootstrap is authoritative for base surface readiness; WS is additive
    // realtime. If snapshots are loaded we keep the runtime usable even when
    // realtime transport is temporarily unavailable.
    let hasHTTPBootstrap = hasReceivedInitialDashboardSnapshot || hasReceivedInitialMissionsSnapshot
    let transportReady = connectionStatus == .connected || hasHTTPBootstrap
    let controlPlaneReady = transportReady
    let dashboardReady = hasReceivedInitialDashboardSnapshot
    let missionsReady = hasReceivedInitialMissionsSnapshot
    return ServerRuntimeReadiness(
      transportReady: transportReady,
      controlPlaneReady: controlPlaneReady,
      dashboardReady: dashboardReady,
      missionsReady: missionsReady
    )
  }
}
