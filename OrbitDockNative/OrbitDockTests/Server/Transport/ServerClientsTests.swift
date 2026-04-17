import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct ServerClientsTests {

  @Test func convertsWebSocketURLsIntoHTTPBaseURLs() throws {
    let secure = try #require(URL(string: "wss://example.com/ws"))
    let insecure = try #require(URL(string: "ws://127.0.0.1:4000/ws"))
    let nested = try #require(URL(string: "wss://example.com/orbitdock/ws"))

    #expect(ServerURLResolver.httpBaseURL(from: secure).absoluteString == "https://example.com")
    #expect(ServerURLResolver.httpBaseURL(from: insecure).absoluteString == "http://127.0.0.1:4000")
    #expect(ServerURLResolver.httpBaseURL(from: nested).absoluteString == "https://example.com/orbitdock")
  }

  @Test func setServerRoleSendsScopedJSONAndAuthorizationHeader() async throws {
    let recorder = RequestRecorder()
    let clients = try ServerClients(
      serverURL: #require(URL(string: "ws://127.0.0.1:4000/ws")),
      authToken: "secret-token",
      dataLoader: { request in
        await recorder.record(request)
        return Self.jsonResponse(
          url: request.url!,
          statusCode: 200,
          json: #"{"is_primary":true}"#
        )
      }
    )

    let isPrimary = try await clients.serverRole.setServerRole(true)
    let request = try #require(await recorder.singleRequest())

    #expect(isPrimary)
    #expect(request.httpMethod == "PUT")
    #expect(request.url?.path == "/api/server/role")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

    let body = try #require(request.httpBody)
    let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(payload["is_primary"] as? Bool == true)
  }

  @Test func setClientPrimaryClaimPostsExpectedBody() async throws {
    let recorder = RequestRecorder()
    let clients = try ServerClients(
      serverURL: #require(URL(string: "http://localhost:4000")),
      authToken: "secret-token",
      dataLoader: { request in
        await recorder.record(request)
        return Self.jsonResponse(
          url: request.url!,
          statusCode: 202,
          json: #"{"accepted":true}"#
        )
      }
    )

    try await clients.serverRole.setClientPrimaryClaim(
      ServerClientIdentity(clientId: "client-1", deviceName: "Robert's MacBook Pro"),
      true
    )

    let request = try #require(await recorder.singleRequest())
    #expect(request.httpMethod == "POST")
    #expect(request.url?.path == "/api/client/primary-claim")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

    let body = try #require(request.httpBody)
    let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(payload["client_id"] as? String == "client-1")
    #expect(payload["device_name"] as? String == "Robert's MacBook Pro")
    #expect(payload["is_primary"] as? Bool == true)
  }

  @Test func browseDirectoryPreservesPathQueryAndDecodesListing() async throws {
    let recorder = RequestRecorder()
    let clients = try ServerClients(
      serverURL: #require(URL(string: "http://localhost:4000")),
      authToken: nil,
      dataLoader: { request in
        await recorder.record(request)
        return Self.jsonResponse(
          url: request.url!,
          statusCode: 200,
          json: #"{"path":"/tmp/project","entries":[]}"#
        )
      }
    )

    let result = try await clients.filesystem.browseDirectory(path: "/tmp/project")
    let request = try #require(await recorder.singleRequest())
    let requestURL = try #require(request.url)
    let components = try #require(URLComponents(url: requestURL, resolvingAgainstBaseURL: false))

    #expect(result.0 == "/tmp/project")
    #expect(result.1.isEmpty)
    #expect(components.path == "/api/fs/browse")
    #expect(components.queryItems?.contains(URLQueryItem(name: "path", value: "/tmp/project")) == true)
  }

  @Test func listSkillsRepeatsCwdQueryItemsAndForceReloadFlag() async throws {
    let recorder = RequestRecorder()
    let clients = try ServerClients(
      serverURL: #require(URL(string: "http://localhost:4000")),
      authToken: nil,
      dataLoader: { request in
        await recorder.record(request)
        return Self.jsonResponse(
          url: request.url!,
          statusCode: 200,
          json: #"{"session_id":"session-1","skills":[],"errors":[]}"#
        )
      }
    )

    let response = try await clients.skills.listSkills(
      sessionId: "session-1",
      cwds: ["/repo/a", "/repo/b"],
      forceReload: true
    )
    let request = try #require(await recorder.singleRequest())
    let requestURL = try #require(request.url)
    let components = try #require(URLComponents(url: requestURL, resolvingAgainstBaseURL: false))
    let cwdValues = components.queryItems?
      .filter { $0.name == "cwd" }
      .compactMap(\.value) ?? []

    #expect(response.sessionId == "session-1")
    #expect(response.skills.isEmpty)
    #expect(response.errors.isEmpty)
    #expect(cwdValues == ["/repo/a", "/repo/b"])
    #expect(components.queryItems?.contains(URLQueryItem(name: "force_reload", value: "true")) == true)
  }

  @Test func surfacesStructuredHTTPFailures() async throws {
    let clients = try ServerClients(
      serverURL: #require(URL(string: "http://localhost:4000")),
      authToken: nil,
      dataLoader: { request in
        Self.jsonResponse(
          url: request.url!,
          statusCode: 409,
          json: #"{"code":"session_not_found","error":"connector missing"}"#
        )
      }
    )

    do {
      _ = try await clients.sessions.resumeSession("missing-session")
      Issue.record("Expected resumeSession to surface the server error.")
    } catch let error as ServerRequestError {
      guard case let .httpStatus(status, code, message) = error else {
        Issue.record("Expected an HTTP status error.")
        return
      }
      #expect(status == 409)
      #expect(code == "session_not_found")
      #expect(message == "connector missing")
    } catch {
      Issue.record("Expected ServerRequestError, got \(error).")
    }
  }

  @Test func surfacesCreateSessionConnectorStartFailures() async throws {
    let clients = try ServerClients(
      serverURL: #require(URL(string: "http://localhost:4000")),
      authToken: nil,
      dataLoader: { request in
        Self.jsonResponse(
          url: request.url!,
          statusCode: 503,
          json: #"{"code":"connector_start_failed","error":"Failed to start Codex connector"}"#
        )
      }
    )

    do {
      _ = try await clients.sessions.createSession(
        SessionsClient.CreateSessionRequest(provider: "codex", cwd: "/tmp/project")
      )
      Issue.record("Expected createSession to surface connector start failures.")
    } catch let error as ServerRequestError {
      guard case let .httpStatus(status, code, message) = error else {
        Issue.record("Expected an HTTP status error.")
        return
      }
      #expect(status == 503)
      #expect(code == "connector_start_failed")
      #expect(message == "Failed to start Codex connector")
    } catch {
      Issue.record("Expected ServerRequestError, got \(error).")
    }
  }

  @Test func ignoresHTTPVersionHeadersForDashboardBootstrap() async throws {
    let clients = try ServerClients(
      serverURL: #require(URL(string: "http://localhost:4000")),
      authToken: nil,
      dataLoader: { request in
        Self.jsonResponse(
          url: request.url!,
          statusCode: 200,
          json: #"{"revision":1,"sessions":[],"conversations":[],"counts":{"attention":0,"running":0,"ready":0,"direct":0}}"#,
          headers: [
            "Content-Type": "application/json",
            "X-OrbitDock-Server-Version": "0.6.0",
            "X-OrbitDock-Minimum-Client-Version": "0.4.0",
          ]
        )
      }
    )

    let snapshot = try await clients.activeSessions.fetchSnapshot()

    #expect(snapshot.conversations.isEmpty)
  }

  @Test func renameSessionDecodesAuthoritativeDetailSnapshotFromAcceptedResponse() async throws {
    let clients = try ServerClients(
      serverURL: #require(URL(string: "http://localhost:4000")),
      authToken: nil,
      dataLoader: { request in
        Self.jsonResponse(
          url: request.url!,
          statusCode: 200,
          json: """
          {
            "accepted": true,
            "session_detail_snapshot": \(Self.detailSnapshotJSON(revision: 12))
          }
          """
        )
      }
    )

    let response = try await clients.sessions.renameSession("session-1", name: "Renamed")

    #expect(response.accepted)
    #expect(response.sessionDetailSnapshot?.revision == 12)
    #expect(response.sessionDetailSnapshot?.session.id == "session-1")
  }

  @Test func missionMutationsDecodeAuthoritativeMissionDetailResponses() async throws {
    let clients = try ServerClients(
      serverURL: #require(URL(string: "http://localhost:4000")),
      authToken: nil,
      dataLoader: { request in
        Self.jsonResponse(
          url: request.url!,
          statusCode: 200,
          json: Self.missionDetailJSON(name: "API Cleanup")
        )
      }
    )

    let updatedMission = try await clients.missions.updateMission(
      "mission-1",
      enabled: true,
      paused: false
    )
    let retriedIssue = try await clients.missions.retryIssue(
      missionId: "mission-1",
      issueId: "issue-1"
    )

    #expect(updatedMission.summary.id == "mission-1")
    #expect(updatedMission.summary.name == "API Cleanup")
    #expect(retriedIssue.issues.count == 1)
    #expect(retriedIssue.issues.first?.issueId == "issue-1")
    #expect(retriedIssue.issues.first?.orchestrationState == .queued)
  }

  private nonisolated static func jsonResponse(
    url: URL,
    statusCode: Int,
    json: String,
    headers: [String: String] = [
      "Content-Type": "application/json",
      "X-OrbitDock-Server-Version": "0.9.0",
      "X-OrbitDock-Minimum-Client-Version": "0.4.0",
    ]
  ) -> (Data, URLResponse) {
    let response = HTTPURLResponse(
      url: url,
      statusCode: statusCode,
      httpVersion: nil,
      headerFields: headers
    )!
    return (Data(json.utf8), response)
  }

  private nonisolated static func detailSnapshotJSON(revision: UInt64) -> String {
    """
    {
      "revision": \(revision),
      "session": {
        "id": "session-1",
        "provider": "claude",
        "project_path": "/tmp/project",
        "project_name": "OrbitDock",
        "status": "active",
        "work_status": "waiting",
        "control_mode": "direct",
        "lifecycle_state": "open",
        "accepts_user_input": true,
        "steerable": false,
        "rows": [],
        "total_row_count": 0,
        "has_more_before": false,
        "pending_approval": null,
        "token_usage": {
          "input_tokens": 0,
          "output_tokens": 0,
          "cached_tokens": 0,
          "context_window": 0
        },
        "token_usage_snapshot_kind": "unknown",
        "allow_bypass_permissions": false,
        "turn_count": 0,
        "turn_diffs": [],
        "subagents": [],
        "is_worktree": false,
        "unread_count": 0,
        "claude_integration_mode": "direct",
        "revision": \(revision)
      }
    }
    """
  }

  private nonisolated static func missionDetailJSON(name: String) -> String {
    """
    {
      "summary": {
        "id": "mission-1",
        "name": "\(name)",
        "repo_root": "/tmp/project",
        "enabled": true,
        "paused": false,
        "tracker_kind": "linear",
        "provider": "claude",
        "provider_strategy": "single",
        "primary_provider": "claude",
        "secondary_provider": null,
        "active_count": 0,
        "queued_count": 1,
        "completed_count": 0,
        "failed_count": 0,
        "parse_error": null,
        "orchestrator_status": "polling",
        "last_polled_at": null,
        "poll_interval": null,
        "mission_file_path": null,
        "tracker_key_source": null
      },
      "issues": [
        {
          "issue_id": "issue-1",
          "identifier": "ENG-42",
          "title": "Fix sync path",
          "tracker_state": "Todo",
          "orchestration_state": "queued",
          "session_id": null,
          "provider": "claude",
          "attempt": 1,
          "error": null,
          "url": null,
          "last_activity": null,
          "started_at": null,
          "completed_at": null,
          "allowed_transitions": ["completed", "failed", "blocked"],
          "work_status": null,
          "last_message": null,
          "pr_url": null
        }
      ],
      "cleanup_prompt": null,
      "settings": null,
      "mission_file_exists": true,
      "mission_file_path": null,
      "workflow_migration_available": false
    }
    """
  }
}

private actor RequestRecorder {
  private var requests: [URLRequest] = []

  func record(_ request: URLRequest) {
    requests.append(request)
  }

  func singleRequest() -> URLRequest? {
    requests.last
  }
}
