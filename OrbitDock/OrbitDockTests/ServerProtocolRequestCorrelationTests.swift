import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct ServerProtocolRequestCorrelationTests {
  @Test func clientRequestMessagesEncodeRequestId() throws {
    let messages: [ClientToServerMessage] = [
      .checkOpenAiKey(requestId: "req-openai"),
      .fetchCodexUsage(requestId: "req-codex-usage"),
      .fetchClaudeUsage(requestId: "req-claude-usage"),
      .listRecentProjects(requestId: "req-projects"),
      .browseDirectory(path: "/tmp", requestId: "req-browse"),
    ]

    for message in messages {
      let data = try JSONEncoder().encode(message)
      let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      let requestId = try #require(payload["request_id"] as? String)
      #expect(requestId.hasPrefix("req-"))
    }
  }

  @Test func serverResponseMessagesDecodeRequestId() throws {
    let directoryJson = #"{"type":"directory_listing","request_id":"req-dir","path":"/tmp","entries":[]}"#
    let projectsJson = #"{"type":"recent_projects_list","request_id":"req-projects","projects":[]}"#
    let keyStatusJson = #"{"type":"open_ai_key_status","request_id":"req-key","configured":true}"#
    let codexUsageJson =
      #"{"type":"codex_usage_result","request_id":"req-codex-usage","error_info":{"code":"not_installed","message":"Codex CLI not installed"}}"#
    let claudeUsageJson =
      #"{"type":"claude_usage_result","request_id":"req-claude-usage","error_info":{"code":"no_credentials","message":"No Claude credentials found"}}"#

    let directoryMessage = try JSONDecoder().decode(ServerToClientMessage.self, from: Data(directoryJson.utf8))
    let projectsMessage = try JSONDecoder().decode(ServerToClientMessage.self, from: Data(projectsJson.utf8))
    let keyStatusMessage = try JSONDecoder().decode(ServerToClientMessage.self, from: Data(keyStatusJson.utf8))
    let codexUsageMessage = try JSONDecoder().decode(ServerToClientMessage.self, from: Data(codexUsageJson.utf8))
    let claudeUsageMessage = try JSONDecoder().decode(ServerToClientMessage.self, from: Data(claudeUsageJson.utf8))

    switch directoryMessage {
      case let .directoryListing(requestId, path, entries):
        #expect(requestId == "req-dir")
        #expect(path == "/tmp")
        #expect(entries.isEmpty)
      default:
        Issue.record("Expected directory_listing")
    }

    switch projectsMessage {
      case let .recentProjectsList(requestId, projects):
        #expect(requestId == "req-projects")
        #expect(projects.isEmpty)
      default:
        Issue.record("Expected recent_projects_list")
    }

    switch keyStatusMessage {
      case let .openAiKeyStatus(requestId, configured):
        #expect(requestId == "req-key")
        #expect(configured)
      default:
        Issue.record("Expected open_ai_key_status")
    }

    switch codexUsageMessage {
      case let .codexUsageResult(requestId, usage, errorInfo):
        #expect(requestId == "req-codex-usage")
        #expect(usage == nil)
        #expect(errorInfo?.code == "not_installed")
      default:
        Issue.record("Expected codex_usage_result")
    }

    switch claudeUsageMessage {
      case let .claudeUsageResult(requestId, usage, errorInfo):
        #expect(requestId == "req-claude-usage")
        #expect(usage == nil)
        #expect(errorInfo?.code == "no_credentials")
      default:
        Issue.record("Expected claude_usage_result")
    }
  }

  @Test func clientRequestMessagesRejectMissingRequestId() {
    let missingRequestIdPayloads = [
      #"{"type":"check_open_ai_key"}"#,
      #"{"type":"fetch_codex_usage"}"#,
      #"{"type":"fetch_claude_usage"}"#,
      #"{"type":"list_recent_projects"}"#,
      #"{"type":"browse_directory","path":"/tmp"}"#,
    ]

    for payload in missingRequestIdPayloads {
      #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(ClientToServerMessage.self, from: Data(payload.utf8))
      }
    }
  }

  @Test func serverResponseMessagesRejectMissingRequestId() {
    let missingRequestIdPayloads = [
      #"{"type":"directory_listing","path":"/tmp","entries":[]}"#,
      #"{"type":"recent_projects_list","projects":[]}"#,
      #"{"type":"open_ai_key_status","configured":true}"#,
      #"{"type":"codex_usage_result","usage":null}"#,
      #"{"type":"claude_usage_result","usage":null}"#,
    ]

    for payload in missingRequestIdPayloads {
      #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(ServerToClientMessage.self, from: Data(payload.utf8))
      }
    }
  }

  @Test func serverInfoMessageDecodesPrimaryFlag() throws {
    let payload =
      #"{"type":"server_info","is_primary":false,"client_primary_claims":[{"client_id":"device-1","device_name":"Robert's iPhone"}]}"#
    let message = try JSONDecoder().decode(ServerToClientMessage.self, from: Data(payload.utf8))
    switch message {
      case let .serverInfo(isPrimary, clientPrimaryClaims):
        #expect(isPrimary == false)
        #expect(clientPrimaryClaims.map(\.clientId) == ["device-1"])
      default:
        Issue.record("Expected server_info")
    }
  }

  @Test func clientSetServerRoleMessageEncodesPrimaryFlag() throws {
    let message = ClientToServerMessage.setServerRole(isPrimary: true)
    let data = try JSONEncoder().encode(message)
    let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(payload["type"] as? String == "set_server_role")
    #expect(payload["is_primary"] as? Bool == true)
  }

  @Test func clientSetClientPrimaryClaimEncodesIdentityAndPrimaryFlag() throws {
    let message = ClientToServerMessage.setClientPrimaryClaim(
      clientId: "device-1",
      deviceName: "Robert's iPhone",
      isPrimary: true
    )
    let data = try JSONEncoder().encode(message)
    let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(payload["type"] as? String == "set_client_primary_claim")
    #expect(payload["client_id"] as? String == "device-1")
    #expect(payload["device_name"] as? String == "Robert's iPhone")
    #expect(payload["is_primary"] as? Bool == true)
  }
}
