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
