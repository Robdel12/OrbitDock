import Foundation
@testable import OrbitDock
import Testing

struct ServerCompatibilityContractsTests {
  @Test func serverMetaDecodesWhenLegacyPayloadOmitsPrimaryClaims() throws {
    let json = """
      {
        "server_version": "0.6.0",
        "compatibility": {
          "compatible": true,
          "server_compatibility": "server_authoritative_session_v1"
        },
        "capabilities": ["dashboard_projection_v1"],
        "is_primary": true,
        "update_status": {
          "update_available": true,
          "latest_version": "v0.7.0",
          "release_url": "https://github.com/Robdel12/OrbitDock/releases/tag/v0.7.0",
          "channel": "stable",
          "checked_at": "2026-03-29T04:55:11.300321+00:00"
        }
      }
      """

    let meta = try JSONDecoder().decode(ServerMetaResponse.self, from: Data(json.utf8))

    #expect(meta.serverVersion == "0.6.0")
    #expect(meta.isPrimary)
    #expect(meta.clientPrimaryClaims.isEmpty)
    #expect(meta.updateStatus?.updateAvailable == true)
    #expect(meta.updateStatus?.latestVersion == "v0.7.0")
  }

  @Test func checkedAtLabelAcceptsFractionalSecondRFC3339Timestamps() {
    let referenceDate = Date(timeIntervalSince1970: 1_743_225_600) // 2025-03-29T05:00:00Z
    let label = relativeServerUpdateCheckedAtLabel(
      "2025-03-29T04:55:11.300321+00:00",
      relativeTo: referenceDate
    )

    #expect(label != "unknown")
  }

  @Test func helloAcceptsCompatibleServerVerdict() throws {
    let hello = ServerHelloMetadata(
      serverVersion: OrbitDockProtocol.releaseVersion,
      compatibility: ServerCompatibilityStatus(
        compatible: true,
        serverCompatibility: OrbitDockProtocol.compatibility,
        reason: nil,
        message: nil
      ),
      capabilities: ["dashboard_projection_v1"]
    )

    #expect(throws: Never.self) {
      try hello.validateCompatibility()
    }
  }

  @Test func helloRejectsIncompatibleServerVerdict() throws {
    let hello = ServerHelloMetadata(
      serverVersion: OrbitDockProtocol.releaseVersion,
      compatibility: ServerCompatibilityStatus(
        compatible: false,
        serverCompatibility: "legacy_contract",
        reason: "upgrade_app",
        message: "Update OrbitDock to a build compatible with server 0.4.0."
      ),
      capabilities: []
    )

    #expect(throws: ServerCompatibilityError.incompatibleServer(
      serverVersion: OrbitDockProtocol.releaseVersion,
      serverCompatibility: "legacy_contract",
      reason: "upgrade_app",
      message: "Update OrbitDock to a build compatible with server 0.4.0."
    )) {
      try hello.validateCompatibility()
    }
  }

  @Test func serverMetaRejectsIncompatibleServerVerdict() throws {
    let meta = ServerMetaResponse(
      serverVersion: OrbitDockProtocol.releaseVersion,
      compatibility: ServerCompatibilityStatus(
        compatible: false,
        serverCompatibility: "legacy_contract",
        reason: "upgrade_server",
        message: "Update the OrbitDock server to work with client 0.5.0."
      ),
      capabilities: [],
      isPrimary: true,
      clientPrimaryClaims: []
    )

    #expect(throws: ServerCompatibilityError.incompatibleServer(
      serverVersion: OrbitDockProtocol.releaseVersion,
      serverCompatibility: "legacy_contract",
      reason: "upgrade_server",
      message: "Update the OrbitDock server to work with client 0.5.0."
    )) {
      try meta.validateCompatibility()
    }
  }

  @Test func httpResponseRejectsIncompatibleServerVerdict() throws {
    let response = HTTPResponse(
      statusCode: 200,
      headers: [
        "X-OrbitDock-Server-Version": OrbitDockProtocol.releaseVersion,
        "X-OrbitDock-Server-Compatibility": "legacy_contract",
        "X-OrbitDock-Compatible": "false",
        "X-OrbitDock-Compatibility-Reason": "upgrade_app",
        "X-OrbitDock-Compatibility-Message": "Update OrbitDock to a build compatible with server 0.4.0.",
      ],
      body: Data()
    )

    #expect(throws: ServerCompatibilityError.incompatibleServer(
      serverVersion: OrbitDockProtocol.releaseVersion,
      serverCompatibility: "legacy_contract",
      reason: "upgrade_app",
      message: "Update OrbitDock to a build compatible with server 0.4.0."
    )) {
      try response.validateServerCompatibilityHeaders()
    }
  }

  @Test func httpResponseRequiresCompatibilityMetadata() throws {
    let response = HTTPResponse(
      statusCode: 200,
      headers: [
        "X-OrbitDock-Server-Version": OrbitDockProtocol.releaseVersion,
      ],
      body: Data()
    )

    #expect(throws: ServerCompatibilityError.missingCompatibilityMetadata(transport: "HTTP")) {
      try response.validateServerCompatibilityHeaders()
    }
  }
}
