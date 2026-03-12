import Foundation

enum ConnectionStatus: Hashable, Sendable {
  case disconnected
  case connecting
  case connected
  case failed(String)
}

extension ConnectionStatus: Equatable {
  nonisolated static func == (lhs: ConnectionStatus, rhs: ConnectionStatus) -> Bool {
    switch (lhs, rhs) {
      case (.disconnected, .disconnected), (.connecting, .connecting), (.connected, .connected):
        true
      case let (.failed(lhsMessage), .failed(rhsMessage)):
        lhsMessage == rhsMessage
      default:
        false
    }
  }
}
