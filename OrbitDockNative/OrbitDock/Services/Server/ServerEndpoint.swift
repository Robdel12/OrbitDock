import Foundation

struct ServerEndpoint: Codable, Equatable, Hashable, Identifiable {
  static let localManagedEndpointID = UUID(uuidString: "0F0D0C0B-4000-4A00-8D00-000000000001")!

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
      id: localManagedEndpointID,
      name: "Local Server",
      wsURL: URL(string: "ws://127.0.0.1:\(defaultPort)/ws")!,
      isLocalManaged: true,
      isEnabled: true,
      isDefault: true
    )
  }
}
