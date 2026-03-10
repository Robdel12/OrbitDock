import Foundation

enum ConnectionStatus: Equatable, Hashable {
  case disconnected
  case connecting
  case connected
  case failed(String)
}
