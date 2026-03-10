import Foundation

struct ControlPlaneClient: Sendable {
  let setServerRole: @Sendable (Bool) async throws -> Bool
  let setClientPrimaryClaim: @Sendable (ServerClientIdentity, Bool) async throws -> Void
}

extension ControlPlaneClient {
  static func live(apiClient: APIClient) -> ControlPlaneClient {
    ControlPlaneClient(
      setServerRole: { isPrimary in
        try await apiClient.setServerRole(isPrimary: isPrimary)
      },
      setClientPrimaryClaim: { identity, isPrimary in
        try await apiClient.setClientPrimaryClaim(
          clientId: identity.clientId,
          deviceName: identity.deviceName,
          isPrimary: isPrimary
        )
      }
    )
  }
}
