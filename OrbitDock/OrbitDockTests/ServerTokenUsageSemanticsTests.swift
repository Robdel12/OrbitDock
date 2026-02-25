import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct ServerTokenUsageSemanticsTests {
  @Test func tokensUpdatedDecodesSnapshotKind() throws {
    let json = #"""
    {
      "type":"tokens_updated",
      "session_id":"session-1",
      "usage":{"input_tokens":1200,"output_tokens":340,"cached_tokens":200,"context_window":8000},
      "snapshot_kind":"mixed_legacy"
    }
    """#

    let message = try JSONDecoder().decode(ServerToClientMessage.self, from: Data(json.utf8))
    switch message {
      case let .tokensUpdated(sessionId, usage, snapshotKind):
        #expect(sessionId == "session-1")
        #expect(usage.inputTokens == 1_200)
        #expect(snapshotKind == .mixedLegacy)
      default:
        Issue.record("Expected tokens_updated")
    }
  }

  @Test func turnDiffSnapshotDecodesSnapshotKind() throws {
    let json = #"""
    {
      "type":"turn_diff_snapshot",
      "session_id":"session-1",
      "turn_id":"turn-42",
      "diff":"diff --git a/file b/file",
      "input_tokens":2500,
      "output_tokens":100,
      "cached_tokens":600,
      "context_window":8000,
      "snapshot_kind":"context_turn"
    }
    """#

    let message = try JSONDecoder().decode(ServerToClientMessage.self, from: Data(json.utf8))
    switch message {
      case let .turnDiffSnapshot(
      sessionId,
      turnId,
      _,
      inputTokens,
      _,
      cachedTokens,
      _,
      snapshotKind
    ):
        #expect(sessionId == "session-1")
        #expect(turnId == "turn-42")
        #expect(inputTokens == 2_500)
        #expect(cachedTokens == 600)
        #expect(snapshotKind == .contextTurn)
      default:
        Issue.record("Expected turn_diff_snapshot")
    }
  }

  @Test func sessionContextHelpersRespectSnapshotSemantics() {
    let codexContextTurn = Session(
      id: "codex-context",
      projectPath: "/tmp/project",
      status: .active,
      workStatus: .working,
      provider: .codex,
      inputTokens: 2_400,
      outputTokens: 100,
      cachedTokens: 600,
      contextWindow: 8_000,
      tokenUsageSnapshotKind: .contextTurn
    )
    #expect(codexContextTurn.effectiveContextInputTokens == 2_400)
    #expect(Int(codexContextTurn.contextFillPercent) == 30)

    let claudeMixedLegacy = Session(
      id: "claude-mixed",
      projectPath: "/tmp/project",
      status: .active,
      workStatus: .working,
      provider: .claude,
      inputTokens: 2_400,
      outputTokens: 100,
      cachedTokens: 600,
      contextWindow: 8_000,
      tokenUsageSnapshotKind: .mixedLegacy
    )
    #expect(claudeMixedLegacy.effectiveContextInputTokens == 3_000)
    #expect(Int(claudeMixedLegacy.contextFillPercent) == 37)

    let claudeUnknown = Session(
      id: "claude-unknown",
      projectPath: "/tmp/project",
      status: .active,
      workStatus: .working,
      provider: .claude,
      inputTokens: 2_400,
      outputTokens: 100,
      cachedTokens: 600,
      contextWindow: 8_000,
      tokenUsageSnapshotKind: .unknown
    )
    #expect(claudeUnknown.effectiveContextInputTokens == 3_000)
  }
}
