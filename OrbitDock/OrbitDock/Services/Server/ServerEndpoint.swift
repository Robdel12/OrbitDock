import Foundation

struct ServerEndpoint: Codable, Equatable, Hashable, Identifiable {
  var id: UUID
  var name: String
  var wsURL: URL
  var isLocalManaged: Bool
  var isEnabled: Bool
  var isDefault: Bool
  var authToken: String?

  init(
    id: UUID = UUID(),
    name: String,
    wsURL: URL,
    isLocalManaged: Bool,
    isEnabled: Bool = true,
    isDefault: Bool = false,
    authToken: String? = nil
  ) {
    self.id = id
    self.name = name
    self.wsURL = wsURL
    self.isLocalManaged = isLocalManaged
    self.isEnabled = isEnabled
    self.isDefault = isDefault
    self.authToken = authToken
  }

  var isRemote: Bool {
    guard let host = wsURL.host else { return false }
    return host != "127.0.0.1" && host != "localhost" && host != "::1"
  }

  static func localDefault(defaultPort: Int = ServerEndpointSettings.defaultPort) -> ServerEndpoint {
    ServerEndpoint(
      name: "Local Server",
      wsURL: URL(string: "ws://127.0.0.1:\(defaultPort)/ws")!,
      isLocalManaged: true,
      isEnabled: true,
      isDefault: true
    )
  }
}
