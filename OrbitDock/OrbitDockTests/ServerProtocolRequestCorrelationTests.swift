import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct ServerProtocolRequestCorrelationTests {
  @Test func clientRequestMessagesEncodeRequestId() throws {
    let messages: [ClientToServerMessage] = [
      .checkOpenAiKey(requestId: "req-openai"),
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

    let directoryMessage = try JSONDecoder().decode(ServerToClientMessage.self, from: Data(directoryJson.utf8))
    let projectsMessage = try JSONDecoder().decode(ServerToClientMessage.self, from: Data(projectsJson.utf8))
    let keyStatusMessage = try JSONDecoder().decode(ServerToClientMessage.self, from: Data(keyStatusJson.utf8))

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
  }

  @Test func clientRequestMessagesRejectMissingRequestId() {
    let missingRequestIdPayloads = [
      #"{"type":"check_open_ai_key"}"#,
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
    ]

    for payload in missingRequestIdPayloads {
      #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(ServerToClientMessage.self, from: Data(payload.utf8))
      }
    }
  }

  @Test func serverInfoMessageDecodesPrimaryFlag() throws {
    let payload = #"{"type":"server_info","is_primary":false}"#
    let message = try JSONDecoder().decode(ServerToClientMessage.self, from: Data(payload.utf8))
    switch message {
      case let .serverInfo(isPrimary):
        #expect(isPrimary == false)
      default:
        Issue.record("Expected server_info")
    }
  }
}
