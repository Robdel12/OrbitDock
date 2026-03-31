import Foundation
@testable import OrbitDock
import Testing

struct ServerHandshakeContractsTests {
  @Test func transportRequestUsesLegacyServerHeaders() {
    let request = try? HTTPRequestBuilder(
      baseURL: URL(string: "http://127.0.0.1:4000")!,
      authToken: nil
    ).build(path: "/api/dashboard", method: "GET")

    #expect(request?.value(forHTTPHeaderField: "X-OrbitDock-Client-Version") == "0.4.0")
    #expect(
      request?.value(forHTTPHeaderField: "X-OrbitDock-Client-Compatibility")
        == "server_authoritative_session_v1"
    )
  }

  @Test func serverHelloDecodesVersionMetadataWithoutValidation() throws {
    let json = """
      {
        "server_version": "0.8.0",
        "minimum_client_version": "0.7.0",
        "capabilities": ["dashboard_projection_v1"]
      }
      """

    let hello = try JSONDecoder().decode(ServerHelloMetadata.self, from: Data(json.utf8))

    #expect(hello.serverVersion == "0.8.0")
    #expect(hello.minimumClientVersion == "0.7.0")
    #expect(hello.capabilities == ["dashboard_projection_v1"])
  }

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
}
