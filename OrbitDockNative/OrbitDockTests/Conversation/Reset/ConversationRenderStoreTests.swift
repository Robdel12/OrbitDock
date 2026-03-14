import XCTest
@testable import OrbitDock

@MainActor
final class ConversationRenderStoreTests: XCTestCase {
  func testUnreadCountAccumulatesOnlyWhenUserIsOffBottomAndClearsOnRepin() {
    let session = ScopedSessionID(endpointId: UUID(), sessionId: "session-1")
    let store = ConversationRenderStore(session: session)

    store.appendUnread(3)
    XCTAssertEqual(store.unreadCount, 0)

    store.setPinnedToBottom(false)
    store.appendUnread(2)
    store.appendUnread(1)

    XCTAssertEqual(store.unreadCount, 3)

    store.setPinnedToBottom(true)

    XCTAssertEqual(store.unreadCount, 0)
    XCTAssertTrue(store.isPinnedToBottom)
  }

  func testFinalStreamingPatchClearsHotStreamingStateWithoutTouchingRows() {
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
            payload: .message(.init(messageID: "message-1", role: .assistant, speaker: "Assistant", text: "Hello", timestamp: nil, contentSignature: 1)),
            sequence: 1
          )
        ],
        oldestLoadedSequence: 1,
        newestLoadedSequence: 1,
        hasMoreHistoryBefore: false
      )
    )

    store.applyStreaming([
      StreamingMessageState(session: session, messageID: "message-1", content: "Hello")
    ])
    XCTAssertEqual(store.streamingMessages["message-1"]?.content, "Hello")
    XCTAssertEqual(store.rows.map(\.id), ["message-1"])

    store.applyStreaming([
      StreamingMessageState(session: session, messageID: "message-1", content: "Hello world", isFinal: true)
    ])

    XCTAssertNil(store.streamingMessages["message-1"])
    XCTAssertEqual(store.rows.map(\.id), ["message-1"])
  }
}
