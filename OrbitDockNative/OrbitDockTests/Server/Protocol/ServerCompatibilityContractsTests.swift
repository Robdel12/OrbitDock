import Foundation
@testable import OrbitDock
import Testing

struct ServerCompatibilityContractsTests {
  @Test func serverMetaDecodesWhenLegacyPayloadOmitsPrimaryClaims() throws {
    let json = """
      {
        "server_version": "0.8.0",
        "minimum_client_version": "0.7.0",
        "capabilities": ["dashboard_projection_v1"],
        "is_primary": true,
        "update_status": {
          "update_available": true,
          "latest_version": "v0.8.0",
          "release_url": "https://github.com/Robdel12/OrbitDock/releases/tag/v0.8.0",
          "channel": "stable",
          "checked_at": "2026-03-29T04:55:11.300321+00:00"
        }
      }
      """

    let meta = try JSONDecoder().decode(ServerMetaResponse.self, from: Data(json.utf8))

    #expect(meta.serverVersion == "0.8.0")
    #expect(meta.minimumClientVersion == "0.7.0")
    #expect(meta.isPrimary)
    #expect(meta.clientPrimaryClaims.isEmpty)
    #expect(meta.updateStatus?.updateAvailable == true)
    #expect(meta.updateStatus?.latestVersion == "v0.8.0")
  }

  @Test func helloAcceptsMatchingVersionHandshake() throws {
    let hello = ServerHelloMetadata(
      serverVersion: OrbitDockProtocol.minimumServerVersion,
      minimumClientVersion: OrbitDockProtocol.clientVersion,
      capabilities: ["dashboard_projection_v1"]
    )

    #expect(throws: Never.self) {
      try hello.validateCompatibility()
    }
  }

  @Test func helloRejectsOlderServerVersion() throws {
    let hello = ServerHelloMetadata(
      serverVersion: "0.6.0",
      minimumClientVersion: OrbitDockProtocol.clientVersion,
      capabilities: []
    )

    #expect(throws: ServerVersionError.serverTooOld(
      serverVersion: "0.6.0",
      minimumServerVersion: OrbitDockProtocol.minimumServerVersion
    )) {
      try hello.validateCompatibility()
    }
  }

  @Test func helloRejectsOlderClientVersion() throws {
    let hello = ServerHelloMetadata(
      serverVersion: OrbitDockProtocol.minimumServerVersion,
      minimumClientVersion: "0.9.0",
      capabilities: []
    )

    #expect(throws: ServerVersionError.clientTooOld(
      clientVersion: OrbitDockProtocol.clientVersion,
      minimumClientVersion: "0.9.0"
    )) {
      try hello.validateCompatibility()
    }
  }

  @Test func serverMetaRejectsOlderServerVersion() throws {
    let meta = ServerMetaResponse(
      serverVersion: "0.6.0",
      minimumClientVersion: OrbitDockProtocol.clientVersion,
      capabilities: [],
      isPrimary: true,
      clientPrimaryClaims: []
    )

    #expect(throws: ServerVersionError.serverTooOld(
      serverVersion: "0.6.0",
      minimumServerVersion: OrbitDockProtocol.minimumServerVersion
    )) {
      try meta.validateCompatibility()
    }
  }

  @Test func httpResponseRejectsOlderServerVersion() throws {
    let response = HTTPResponse(
      statusCode: 200,
      headers: [
        "X-OrbitDock-Server-Version": "0.6.0",
        "X-OrbitDock-Minimum-Client-Version": OrbitDockProtocol.clientVersion,
      ],
      body: Data()
    )

    #expect(throws: ServerVersionError.serverTooOld(
      serverVersion: "0.6.0",
      minimumServerVersion: OrbitDockProtocol.minimumServerVersion
    )) {
      try response.validateServerVersionHeaders()
    }
  }

  @Test func httpResponseAllowsMissingVersionMetadata() throws {
    let response = HTTPResponse(
      statusCode: 200,
      headers: [
        "X-OrbitDock-Server-Version": OrbitDockProtocol.minimumServerVersion,
      ],
      body: Data()
    )

    #expect(throws: Never.self) {
      try response.validateServerVersionHeaders()
    }
  }
}
