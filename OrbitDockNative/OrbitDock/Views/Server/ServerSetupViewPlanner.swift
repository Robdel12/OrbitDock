import Foundation

enum ServerSetupConnectError: Error, Equatable {
  case missingHost
  case invalidHost
  case missingToken

  var message: String {
    switch self {
      case .missingHost:
        "Enter a server host address."
      case .invalidHost:
        "Enter a valid host (e.g. 10.0.0.5:4000 or https://host.example)."
      case .missingToken:
        "Auth token is required. Run `orbitdock auth local-token` to get yours."
    }
  }
}

enum ServerSetupViewPlanner {
  static func defaultHost() -> String {
    #if os(macOS)
      "127.0.0.1"
    #else
      ""
    #endif
  }

  static func buildEndpoint(
    host: String,
    authToken: String,
    existingEndpoints: [ServerEndpoint],
    defaultPort: Int,
    buildURL: (String) -> URL?
  ) -> Result<[ServerEndpoint], ServerSetupConnectError> {
    let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedHost.isEmpty else {
      return .failure(.missingHost)
    }

    guard let url = buildURL(trimmedHost) else {
      return .failure(.invalidHost)
    }

    let trimmedToken = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedToken.isEmpty else {
      return .failure(.missingToken)
    }

    // Check if there's an existing endpoint with the same URL to update
    let matchingId = existingEndpoints.first(where: { $0.wsURL == url })?.id

    let endpointId = matchingId ?? UUID()
    let endpoint = ServerEndpoint(
      id: endpointId,
      name: endpointName(for: trimmedHost),
      wsURL: url,
      isLocalManaged: false,
      isEnabled: true,
      isDefault: true,
      authToken: trimmedToken
    )

    var updated = existingEndpoints
    if let index = updated.firstIndex(where: { $0.id == endpointId }) {
      updated[index] = endpoint
    } else {
      updated.append(endpoint)
    }

    // Make this endpoint the only default
    for index in updated.indices {
      updated[index].isDefault = updated[index].id == endpointId
    }

    return .success(updated)
  }

  static func buildLocalEndpoint(
    authToken: String,
    existingEndpoints: [ServerEndpoint],
    defaultPort: Int
  ) -> Result<[ServerEndpoint], ServerSetupConnectError> {
    let trimmedToken = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedToken.isEmpty else {
      return .failure(.missingToken)
    }

    let localId = ServerEndpoint.localManagedEndpointID
    var local = ServerEndpoint.localDefault(defaultPort: defaultPort)
    local.authToken = trimmedToken
    local.isEnabled = true
    local.isDefault = true

    var updated = existingEndpoints
    if let index = updated.firstIndex(where: { $0.id == localId }) {
      updated[index] = local
    } else {
      updated.append(local)
    }

    for index in updated.indices {
      updated[index].isDefault = updated[index].id == localId
    }

    return .success(updated)
  }

  static func canConnect(host: String, authToken: String) -> Bool {
    let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedToken = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmedHost.isEmpty && !trimmedToken.isEmpty
  }

  private static func endpointName(for host: String) -> String {
    let lowered = host.lowercased()
    if lowered == "127.0.0.1" || lowered == "localhost" || lowered == "::1" {
      return "Local Server"
    }
    return "Remote Server"
  }
}
