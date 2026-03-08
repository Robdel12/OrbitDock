import Foundation
@testable import OrbitDock
import Testing

struct ServerAppStateConversationBootstrapWindowTests {
  @Test func bootstrapBackfillIsRequiredWhenWindowStartsMidTurn() {
    let messages = [
      TranscriptMessage(
        id: "assistant-1",
        sequence: 10,
        type: .assistant,
        content: "Continuing an existing turn",
        timestamp: Date(timeIntervalSince1970: 10)
      ),
      TranscriptMessage(
        id: "tool-1",
        sequence: 11,
        type: .tool,
        content: "Run search",
        timestamp: Date(timeIntervalSince1970: 11),
        toolName: "grep"
      ),
      TranscriptMessage(
        id: "assistant-2",
        sequence: 12,
        type: .assistant,
        content: "Wrapped up",
        timestamp: Date(timeIntervalSince1970: 12)
      ),
    ]

    #expect(ServerAppState.requiresConversationBootstrapBackfill(
      messages: messages,
      hasMoreHistoryBefore: true,
      minimumTurnCount: 4
    ))
  }

  @Test func bootstrapBackfillIsRequiredWhenRecentWindowHasTooFewTurns() {
    let messages = [
      TranscriptMessage(
        id: "user-1",
        sequence: 20,
        type: .user,
        content: "One",
        timestamp: Date(timeIntervalSince1970: 20)
      ),
      TranscriptMessage(
        id: "assistant-1",
        sequence: 21,
        type: .assistant,
        content: "A",
        timestamp: Date(timeIntervalSince1970: 21)
      ),
      TranscriptMessage(
        id: "user-2",
        sequence: 22,
        type: .user,
        content: "Two",
        timestamp: Date(timeIntervalSince1970: 22)
      ),
      TranscriptMessage(
        id: "assistant-2",
        sequence: 23,
        type: .assistant,
        content: "B",
        timestamp: Date(timeIntervalSince1970: 23)
      ),
    ]

    #expect(ServerAppState.requiresConversationBootstrapBackfill(
      messages: messages,
      hasMoreHistoryBefore: true,
      minimumTurnCount: 4
    ))
  }

  @Test func bootstrapBackfillIsNotRequiredForCoherentRecentWindow() {
    let messages = [
      TranscriptMessage(id: "user-1", sequence: 30, type: .user, content: "One", timestamp: Date(timeIntervalSince1970: 30)),
      TranscriptMessage(id: "assistant-1", sequence: 31, type: .assistant, content: "A", timestamp: Date(timeIntervalSince1970: 31)),
      TranscriptMessage(id: "user-2", sequence: 32, type: .user, content: "Two", timestamp: Date(timeIntervalSince1970: 32)),
      TranscriptMessage(id: "assistant-2", sequence: 33, type: .assistant, content: "B", timestamp: Date(timeIntervalSince1970: 33)),
      TranscriptMessage(id: "user-3", sequence: 34, type: .user, content: "Three", timestamp: Date(timeIntervalSince1970: 34)),
      TranscriptMessage(id: "assistant-3", sequence: 35, type: .assistant, content: "C", timestamp: Date(timeIntervalSince1970: 35)),
      TranscriptMessage(id: "user-4", sequence: 36, type: .user, content: "Four", timestamp: Date(timeIntervalSince1970: 36)),
      TranscriptMessage(id: "assistant-4", sequence: 37, type: .assistant, content: "D", timestamp: Date(timeIntervalSince1970: 37)),
    ]

    #expect(!ServerAppState.requiresConversationBootstrapBackfill(
      messages: messages,
      hasMoreHistoryBefore: true,
      minimumTurnCount: 4
    ))
  }

  @Test func bootstrapBackfillStopsWhenThereIsNoOlderHistory() {
    let messages = [
      TranscriptMessage(
        id: "assistant-1",
        sequence: 0,
        type: .assistant,
        content: "Only message",
        timestamp: Date(timeIntervalSince1970: 40)
      )
    ]

    #expect(!ServerAppState.requiresConversationBootstrapBackfill(
      messages: messages,
      hasMoreHistoryBefore: false,
      minimumTurnCount: 4
    ))
  }
}
