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

  @Test func subscribeSessionOmitsIncludeSnapshotByDefault() throws {
    let message = ClientToServerMessage.subscribeSession(sessionId: "session-1", sinceRevision: 42)
    let data = try JSONEncoder().encode(message)
    let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(payload["type"] as? String == "subscribe_session")
    #expect(payload["session_id"] as? String == "session-1")
    #expect(payload["since_revision"] as? UInt64 == 42)
    #expect(payload["include_snapshot"] == nil)
  }

  @Test func subscribeSessionSupportsReplayOnlyEncodingAndDecoding() throws {
    let message = ClientToServerMessage.subscribeSession(
      sessionId: "session-2",
      sinceRevision: 100,
      includeSnapshot: false
    )
    let data = try JSONEncoder().encode(message)
    let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(payload["include_snapshot"] as? Bool == false)

    let parsed = try JSONDecoder().decode(ClientToServerMessage.self, from: data)
    switch parsed {
      case let .subscribeSession(sessionId, sinceRevision, includeSnapshot):
        #expect(sessionId == "session-2")
        #expect(sinceRevision == 100)
        #expect(includeSnapshot == false)
      default:
        Issue.record("Expected subscribe_session")
    }
  }

  @Test func unsubscribeSessionRoundTripsSessionIdentity() throws {
    let message = ClientToServerMessage.unsubscribeSession(sessionId: "session-9")
    let data = try JSONEncoder().encode(message)
    let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(payload["type"] as? String == "unsubscribe_session")
    #expect(payload["session_id"] as? String == "session-9")

    let parsed = try JSONDecoder().decode(ClientToServerMessage.self, from: data)
    switch parsed {
      case let .unsubscribeSession(sessionId):
        #expect(sessionId == "session-9")
      default:
        Issue.record("Expected unsubscribe_session")
    }
  }

  @Test func subscribeSessionRejectsMissingSessionID() {
    let payload = #"{"type":"subscribe_session"}"#
    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(ClientToServerMessage.self, from: Data(payload.utf8))
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
