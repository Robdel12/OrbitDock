import Foundation
@testable import OrbitDock
import Testing

@Suite("ConversationRenderStore")
@MainActor
struct ConversationRenderStoreTests {
  @Test func unreadCountAccumulatesOnlyWhenUserIsOffBottomAndClearsOnRepin() {
    let session = ScopedSessionID(endpointId: UUID(), sessionId: "session-1")
    let store = ConversationRenderStore(session: session)

    store.appendUnread(3)
    #expect(store.unreadCount == 0)

    store.setPinnedToBottom(false)
    store.appendUnread(2)
    store.appendUnread(1)

    #expect(store.unreadCount == 3)

    store.setPinnedToBottom(true)

    #expect(store.unreadCount == 0)
    #expect(store.isPinnedToBottom)
  }

  @Test func finalStreamingPatchClearsHotStreamingStateWithoutTouchingRows() {
    let session = ScopedSessionID(endpointId: UUID(), sessionId: "session-2")
    let store = ConversationRenderStore(session: session)

    store.applyStructure(
      ConversationStructureSnapshot(
        session: session,
        rows: [
          ConversationRowRecord(
            id: "message-1",
            session: session,
            kind: .message,
            payload: .message(.init(
              messageID: "message-1",
              role: .assistant,
              speaker: "Assistant",
              text: "Hello",
              timestamp: nil,
              contentSignature: 1
            )),
            sequence: 1
          ),
        ],
        oldestLoadedSequence: 1,
        newestLoadedSequence: 1,
        hasMoreHistoryBefore: false
      )
    )

    store.applyStreaming([
      StreamingMessageState(session: session, messageID: "message-1", content: "Hello"),
    ])
    #expect(store.streamingMessages["message-1"]?.content == "Hello")
    #expect(store.rows.map { $0.id } == ["message-1"])

    store.applyStreaming([
      StreamingMessageState(session: session, messageID: "message-1", content: "Hello world", isFinal: true),
    ])

    #expect(store.streamingMessages["message-1"] == nil)
    #expect(store.rows.map { $0.id } == ["message-1"])
  }
}
