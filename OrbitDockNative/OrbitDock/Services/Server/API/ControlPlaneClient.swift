import Foundation

struct ControlPlaneClient: Sendable {
  private enum Implementation: Sendable {
    case live(ServerHTTPClient)
    case test(
      setServerRole: @Sendable (Bool) async throws -> Bool,
      setClientPrimaryClaim: @Sendable (ServerClientIdentity, Bool) async throws -> Void
    )
  }

  private let implementation: Implementation

  init(http: ServerHTTPClient) {
    self.implementation = .live(http)
  }

  init(
    setServerRole: @escaping @Sendable (Bool) async throws -> Bool,
    setClientPrimaryClaim: @escaping @Sendable (ServerClientIdentity, Bool) async throws -> Void
  ) {
    self.implementation = .test(
      setServerRole: setServerRole,
      setClientPrimaryClaim: setClientPrimaryClaim
    )
  }

  func setServerRole(_ isPrimary: Bool) async throws -> Bool {
    switch implementation {
      case let .live(http):
        let body = try JSONSerialization.data(withJSONObject: ["is_primary": isPrimary])
        let response = try await http.sendRaw(
          path: "/api/server/role",
          method: "PUT",
          bodyData: body
        )
        let payload = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        return payload?["is_primary"] as? Bool ?? isPrimary

      case let .test(setServerRole, _):
        return try await setServerRole(isPrimary)
    }
  }

  func setClientPrimaryClaim(_ identity: ServerClientIdentity, _ isPrimary: Bool) async throws {
    switch implementation {
      case let .live(http):
        let body = try JSONSerialization.data(withJSONObject: [
          "client_id": identity.clientId,
          "device_name": identity.deviceName,
          "is_primary": isPrimary,
        ])
        _ = try await http.sendRaw(
          path: "/api/client/primary-claim",
          method: "POST",
          bodyData: body
        )

      case let .test(_, setClientPrimaryClaim):
        try await setClientPrimaryClaim(identity, isPrimary)
    }
  }
}
