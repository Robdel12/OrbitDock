import Foundation

struct ServerClientIdentity: Sendable {
  let clientId: String
  let deviceName: String
}

struct SessionsSummaryClient: Sendable {
  private enum Implementation: Sendable {
    case live(ServerHTTPClient)
    case test(fetchSnapshot: @Sendable () async throws -> ServerSessionsSummarySnapshotPayload)
  }

  private let implementation: Implementation

  init(http: ServerHTTPClient) {
    self.implementation = .live(http)
  }

  init(
    fetchSnapshot: @escaping @Sendable () async throws -> ServerSessionsSummarySnapshotPayload = {
      ServerSessionsSummarySnapshotPayload(
        revision: 0,
        counts: ServerSessionsSummaryCounts(total: 0, active: 0, working: 0, attention: 0, ready: 0),
        activeSessions: [],
        recentSessions: []
      )
    }
  ) {
    self.implementation = .test(fetchSnapshot: fetchSnapshot)
  }

  func fetchSnapshot() async throws -> ServerSessionsSummarySnapshotPayload {
    switch implementation {
      case let .live(http):
        return try await http.get("/api/sessions/summary")

      case let .test(fetchSnapshot):
        return try await fetchSnapshot()
    }
  }
}

struct ServerRoleClient: Sendable {
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
