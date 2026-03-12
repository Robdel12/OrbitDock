import Foundation

enum RootShellEndpointFilter: Hashable, Sendable {
  case all
  case endpoint(UUID)
}

extension RootShellEndpointFilter: Equatable {
  nonisolated static func == (lhs: RootShellEndpointFilter, rhs: RootShellEndpointFilter) -> Bool {
    switch (lhs, rhs) {
      case (.all, .all):
        true
      case let (.endpoint(lhsID), .endpoint(rhsID)):
        lhsID == rhsID
      default:
        false
    }
  }
}

enum RootShellEvent: Sendable {
  case seed(
    endpointId: UUID,
    records: [RootSessionNode]
  )
  case sessionsList(
    endpointId: UUID,
    endpointName: String?,
    connectionStatus: ConnectionStatus,
    sessions: [ServerSessionListItem]
  )
  case sessionCreated(
    endpointId: UUID,
    endpointName: String?,
    connectionStatus: ConnectionStatus,
    session: ServerSessionListItem
  )
  case sessionUpdated(
    endpointId: UUID,
    endpointName: String?,
    connectionStatus: ConnectionStatus,
    session: ServerSessionListItem
  )
  case sessionEnded(
    endpointId: UUID,
    sessionId: String,
    reason: String
  )
  case endpointConnectionChanged(
    endpointId: UUID,
    endpointName: String?,
    connectionStatus: ConnectionStatus
  )
  case endpointFilterChanged(RootShellEndpointFilter)
}
