import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct StreamingMessageRegistryTests {
  @Test func classifiesInProgressAssistantContentAsStreamingPatch() {
    let existing = TranscriptMessage(
      id: "msg-1",
      type: .assistant,
      content: "hello",
      timestamp: Date(),
      isInProgress: true
    )
    let changes = ServerMessageChanges(
      content: "hello there",
      toolOutput: nil,
      isError: nil,
      isInProgress: true,
      durationMs: nil
    )

    let route = StreamingMessageRegistry.classify(existing: existing, changes: changes, messageId: "msg-1")

    #expect(route == .streamingPatch(messageId: "msg-1"))
  }

  @Test func treatsCompletionAsStructural() {
    let existing = TranscriptMessage(
      id: "msg-1",
      type: .assistant,
      content: "hello",
      timestamp: Date(),
      isInProgress: true
    )
    let changes = ServerMessageChanges(
      content: "done",
      toolOutput: nil,
      isError: nil,
      isInProgress: false,
      durationMs: nil
    )

    let route = StreamingMessageRegistry.classify(existing: existing, changes: changes, messageId: "msg-1")

    #expect(route == .structural)
  }

  @Test func flushesSinglePendingMessageAsPatch() {
    var registry = StreamingMessageRegistry()

    let shouldSchedule = registry.enqueuePatch(messageId: "msg-1")
    let outcome = registry.flushPendingPatches()

    #expect(shouldSchedule)
    #expect(outcome == .patch(ConversationStreamingPatch(messageId: "msg-1"), revision: 1))
    #expect(registry.latestPatch == ConversationStreamingPatch(messageId: "msg-1"))
    #expect(registry.revision == 1)
  }

  @Test func flushesMultiplePendingMessagesAsStructuralReset() {
    var registry = StreamingMessageRegistry()

    _ = registry.enqueuePatch(messageId: "msg-1")
    _ = registry.enqueuePatch(messageId: "msg-2")
    let outcome = registry.flushPendingPatches()

    #expect(outcome == .structuralReset)
    #expect(registry.latestPatch == nil)
    #expect(registry.revision == 0)
  }

  @Test func structuralResetClearsPendingAndLatestPatch() {
    var registry = StreamingMessageRegistry()

    _ = registry.enqueuePatch(messageId: "msg-1")
    _ = registry.flushPendingPatches()
    registry.resetForStructuralChange()

    #expect(registry.latestPatch == nil)
    #expect(registry.flushPendingPatches() == .none)
  }
}
