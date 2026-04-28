import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct ServerProtocolRequestCorrelationTests {
  @Test func shellMessagesEncodeAndDecodeOutcome() throws {
    let message = ServerToClientMessage.shellOutput(
      sessionId: "session-1",
      requestId: "shell-1",
      stdout: "output",
      stderr: "",
      exitCode: 124,
      durationMs: 1_500,
      outcome: .timedOut
    )

    let data = try JSONEncoder().encode(message)
    let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(payload["type"] as? String == "shell_output")
    #expect(payload["outcome"] as? String == "timed_out")

    let parsed = try JSONDecoder().decode(ServerToClientMessage.self, from: data)
    switch parsed {
      case let .shellOutput(sessionId, requestId, stdout, stderr, exitCode, durationMs, outcome):
        #expect(sessionId == "session-1")
        #expect(requestId == "shell-1")
        #expect(stdout == "output")
        #expect(stderr.isEmpty)
        #expect(exitCode == 124)
        #expect(durationMs == 1_500)
        #expect(outcome == .timedOut)
      default:
        Issue.record("Expected shell_output")
    }
  }

  @Test func subscribeSessionSurfaceOmitsSinceRevisionWhenUnset() throws {
    let message = ClientToServerMessage.subscribeSessionSurface(
      sessionId: "session-1",
      surface: .detail,
      sinceRevision: nil
    )
    let data = try JSONEncoder().encode(message)
    let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(payload["type"] as? String == "subscribe_session_surface")
    #expect(payload["session_id"] as? String == "session-1")
    #expect(payload["surface"] as? String == "detail")
    #expect(payload["since_revision"] == nil)
  }

  @Test func subscribeActiveSessionsSupportsReplayOnlyEncoding() throws {
    let message = ClientToServerMessage.subscribeActiveSessions(sinceRevision: 91)
    let data = try JSONEncoder().encode(message)
    let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(payload["type"] as? String == "subscribe_active_sessions")
    #expect(payload["since_revision"] as? UInt64 == 91)
  }

  @Test func subscribeArchivedSessionsSupportsReplayOnlyEncoding() throws {
    let message = ClientToServerMessage.subscribeArchivedSessions(sinceRevision: 17)
    let data = try JSONEncoder().encode(message)
    let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(payload["type"] as? String == "subscribe_archived_sessions")
    #expect(payload["since_revision"] as? UInt64 == 17)
  }

  @Test func subscribeSessionsSummarySupportsReplayOnlyEncoding() throws {
    let message = ClientToServerMessage.subscribeSessionsSummary(sinceRevision: 9)
    let data = try JSONEncoder().encode(message)
    let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(payload["type"] as? String == "subscribe_sessions_summary")
    #expect(payload["since_revision"] as? UInt64 == 9)
  }

  @Test func subscribeMissionEncodesMissionIdentity() throws {
    let message = ClientToServerMessage.subscribeMission(missionId: "mission-1")
    let data = try JSONEncoder().encode(message)
    let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(payload["type"] as? String == "subscribe_mission")
    #expect(payload["mission_id"] as? String == "mission-1")
  }

  @Test func unsubscribeMissionsEncodesType() throws {
    let message = ClientToServerMessage.unsubscribeMissions
    let data = try JSONEncoder().encode(message)
    let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(payload["type"] as? String == "unsubscribe_missions")
  }

  @Test func unsubscribeMissionEncodesMissionIdentity() throws {
    let message = ClientToServerMessage.unsubscribeMission(missionId: "mission-1")
    let data = try JSONEncoder().encode(message)
    let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(payload["type"] as? String == "unsubscribe_mission")
    #expect(payload["mission_id"] as? String == "mission-1")
  }

  @Test func unsubscribeSessionsSummaryEncodesType() throws {
    let message = ClientToServerMessage.unsubscribeSessionsSummary
    let data = try JSONEncoder().encode(message)
    let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(payload["type"] as? String == "unsubscribe_sessions_summary")
  }

  @Test func unsubscribeActiveSessionsEncodesType() throws {
    let message = ClientToServerMessage.unsubscribeActiveSessions
    let data = try JSONEncoder().encode(message)
    let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(payload["type"] as? String == "unsubscribe_active_sessions")
  }

  @Test func unsubscribeArchivedSessionsEncodesType() throws {
    let message = ClientToServerMessage.unsubscribeArchivedSessions
    let data = try JSONEncoder().encode(message)
    let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(payload["type"] as? String == "unsubscribe_archived_sessions")
  }

  @Test func subscribeSessionSurfaceSupportsReplayOnlyEncoding() throws {
    let message = ClientToServerMessage.subscribeSessionSurface(
      sessionId: "session-2",
      surface: .conversation,
      sinceRevision: 100
    )
    let data = try JSONEncoder().encode(message)
    let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(payload["type"] as? String == "subscribe_session_surface")
    #expect(payload["session_id"] as? String == "session-2")
    #expect(payload["surface"] as? String == "conversation")
    #expect(payload["since_revision"] as? UInt64 == 100)
  }

  @Test func unsubscribeSessionSurfaceEncodesSessionIdentity() throws {
    let message = ClientToServerMessage.unsubscribeSessionSurface(
      sessionId: "session-9",
      surface: .detail
    )
    let data = try JSONEncoder().encode(message)
    let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(payload["type"] as? String == "unsubscribe_session_surface")
    #expect(payload["session_id"] as? String == "session-9")
    #expect(payload["surface"] as? String == "detail")
  }

  @Test func subscribeToolPtyEncodesToolAndSessionIdentifiers() throws {
    let message = ClientToServerMessage.subscribeToolPty(
      toolId: "tool-1",
      sessionId: "session-3"
    )
    let data = try JSONEncoder().encode(message)
    let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(payload["type"] as? String == "subscribe_tool_pty")
    #expect(payload["tool_id"] as? String == "tool-1")
    #expect(payload["session_id"] as? String == "session-3")
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

  @Test func activeSessionsInvalidatedRoundTripsRevision() throws {
    let message = ServerToClientMessage.activeSessionsInvalidated(revision: 42)
    let data = try JSONEncoder().encode(message)
    let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(payload["type"] as? String == "active_sessions_invalidated")
    #expect(payload["revision"] as? UInt64 == 42)

    let parsed = try JSONDecoder().decode(ServerToClientMessage.self, from: data)
    switch parsed {
      case let .activeSessionsInvalidated(revision):
        #expect(revision == 42)
      default:
        Issue.record("Expected active_sessions_invalidated")
    }
  }

  @Test func archivedSessionsInvalidatedRoundTripsRevision() throws {
    let message = ServerToClientMessage.archivedSessionsInvalidated(revision: 24)
    let data = try JSONEncoder().encode(message)
    let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(payload["type"] as? String == "archived_sessions_invalidated")
    #expect(payload["revision"] as? UInt64 == 24)

    let parsed = try JSONDecoder().decode(ServerToClientMessage.self, from: data)
    switch parsed {
      case let .archivedSessionsInvalidated(revision):
        #expect(revision == 24)
      default:
        Issue.record("Expected archived_sessions_invalidated")
    }
  }

  @Test func sessionsSummaryInvalidatedRoundTripsRevision() throws {
    let message = ServerToClientMessage.sessionsSummaryInvalidated(revision: 11)
    let data = try JSONEncoder().encode(message)
    let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(payload["type"] as? String == "sessions_summary_invalidated")
    #expect(payload["revision"] as? UInt64 == 11)

    let parsed = try JSONDecoder().decode(ServerToClientMessage.self, from: data)
    switch parsed {
      case let .sessionsSummaryInvalidated(revision):
        #expect(revision == 11)
      default:
        Issue.record("Expected sessions_summary_invalidated")
    }
  }

  @Test func missionsInvalidatedRoundTripsRevision() throws {
    let message = ServerToClientMessage.missionsInvalidated(revision: 7)
    let data = try JSONEncoder().encode(message)
    let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(payload["type"] as? String == "missions_invalidated")
    #expect(payload["revision"] as? UInt64 == 7)

    let parsed = try JSONDecoder().decode(ServerToClientMessage.self, from: data)
    switch parsed {
      case let .missionsInvalidated(revision):
        #expect(revision == 7)
      default:
        Issue.record("Expected missions_invalidated")
    }
  }

  @Test func missionInvalidatedRoundTripsMissionIdentityAndRevision() throws {
    let message = ServerToClientMessage.missionInvalidated(missionId: "mission-1", revision: 9)
    let data = try JSONEncoder().encode(message)
    let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(payload["type"] as? String == "mission_invalidated")
    #expect(payload["mission_id"] as? String == "mission-1")
    #expect(payload["revision"] as? UInt64 == 9)

    let parsed = try JSONDecoder().decode(ServerToClientMessage.self, from: data)
    switch parsed {
      case let .missionInvalidated(missionId, revision):
        #expect(missionId == "mission-1")
        #expect(revision == 9)
      default:
        Issue.record("Expected mission_invalidated")
    }
  }

  @Test func serverTokenMessagesEncodeSnapshotKind() throws {
    let usage = ServerTokenUsage(
      inputTokens: 100,
      outputTokens: 20,
      cachedTokens: 10,
      contextWindow: 8_000
    )

    let tokensUpdated = ServerToClientMessage.tokensUpdated(
      sessionId: "session-1",
      usage: usage,
      snapshotKind: .contextTurn
    )
    let tokensData = try JSONEncoder().encode(tokensUpdated)
    let tokensPayload = try #require(JSONSerialization.jsonObject(with: tokensData) as? [String: Any])
    #expect(tokensPayload["snapshot_kind"] as? String == "context_turn")

    let turnDiffSnapshot = ServerToClientMessage.turnDiffSnapshot(
      sessionId: "session-1",
      turnId: "turn-1",
      diff: "diff --git a/file b/file",
      inputTokens: 100,
      outputTokens: 20,
      cachedTokens: 10,
      contextWindow: 8_000,
      snapshotKind: .contextTurn
    )
    let turnData = try JSONEncoder().encode(turnDiffSnapshot)
    let turnPayload = try #require(JSONSerialization.jsonObject(with: turnData) as? [String: Any])
    #expect(turnPayload["snapshot_kind"] as? String == "context_turn")
  }
}
