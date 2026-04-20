import Foundation

enum ServerSessionSurface: String, Codable, CaseIterable, Sendable {
  case detail
  case composer
  case conversation
  case review
  case capabilities
}

struct ServerHelloMetadata: Codable, Sendable {
  let serverVersion: String
  let minimumClientVersion: String
  let capabilities: [String]

  enum CodingKeys: String, CodingKey {
    case serverVersion = "server_version"
    case minimumClientVersion = "minimum_client_version"
    case capabilities
  }
}

struct ServerMetaResponse: Codable, Sendable {
  let serverVersion: String
  let minimumClientVersion: String
  let capabilities: [String]
  let serverInstanceId: String?
  let isPrimary: Bool
  let clientPrimaryClaims: [ServerClientPrimaryClaim]
  let updateStatus: ServerUpdateStatus?

  enum CodingKeys: String, CodingKey {
    case serverVersion = "server_version"
    case minimumClientVersion = "minimum_client_version"
    case capabilities
    case serverInstanceId = "server_instance_id"
    case isPrimary = "is_primary"
    case clientPrimaryClaims = "client_primary_claims"
    case updateStatus = "update_status"
  }

  init(
    serverVersion: String,
    minimumClientVersion: String,
    capabilities: [String],
    serverInstanceId: String?,
    isPrimary: Bool,
    clientPrimaryClaims: [ServerClientPrimaryClaim],
    updateStatus: ServerUpdateStatus? = nil
  ) {
    self.serverVersion = serverVersion
    self.minimumClientVersion = minimumClientVersion
    self.capabilities = capabilities
    self.serverInstanceId = serverInstanceId
    self.isPrimary = isPrimary
    self.clientPrimaryClaims = clientPrimaryClaims
    self.updateStatus = updateStatus
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    serverVersion = try container.decode(String.self, forKey: .serverVersion)
    minimumClientVersion = try container.decode(String.self, forKey: .minimumClientVersion)
    capabilities = try container.decode([String].self, forKey: .capabilities)
    serverInstanceId = try container.decodeIfPresent(String.self, forKey: .serverInstanceId)
    isPrimary = try container.decode(Bool.self, forKey: .isPrimary)
    clientPrimaryClaims =
      try container.decodeIfPresent([ServerClientPrimaryClaim].self, forKey: .clientPrimaryClaims) ?? []
    updateStatus = try container.decodeIfPresent(ServerUpdateStatus.self, forKey: .updateStatus)
  }
}
