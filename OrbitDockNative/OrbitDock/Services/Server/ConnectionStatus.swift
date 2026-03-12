import Foundation

enum ConnectionStatus: Equatable, Hashable, Sendable {
  case disconnected
  case connecting
  case connected
  case failed(String)
}
