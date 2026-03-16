@testable import OrbitDock
import XCTest

final class ConversationStructureStoreTests: XCTestCase {
  func testBootstrapAndPrependPreserveOrderedRows() {
    let session = ScopedSessionID(endpointId: UUID(), sessionId: "session-1")
    var store = ConversationStructureStore(session: session)

    store.apply(.bootstrap(
      rows: [
        ConversationRowRecord(
          id: "message-2",
          session: session,
          kind: .message,
          payload: .message(.init(
            messageID: "message-2",
            role: .assistant,
            speaker: "Assistant",
            text: "two",
            timestamp: nil,
            contentSignature: 2
          )),
          sequence: 2
        ),
        ConversationRowRecord(
          id: "message-3",
          session: session,
          kind: .message,
          payload: .message(.init(
            messageID: "message-3",
            role: .assistant,
            speaker: "Assistant",
            text: "three",
            timestamp: nil,
            contentSignature: 3
          )),
          sequence: 3
        ),
      ],
      oldestLoadedSequence: 2,
      newestLoadedSequence: 3,
      hasMoreHistoryBefore: true
    ))

    store.apply(.prepend(
      rows: [
        ConversationRowRecord(
          id: "message-1",
          session: session,
          kind: .message,
          payload: .message(.init(
            messageID: "message-1",
            role: .assistant,
            speaker: "Assistant",
            text: "one",
            timestamp: nil,
            contentSignature: 1
          )),
          sequence: 1
        ),
      ],
      oldestLoadedSequence: 1,
      hasMoreHistoryBefore: false
    ))

    XCTAssertEqual(store.snapshot.rows.map(\.id), ["message-1", "message-2", "message-3"])
    XCTAssertEqual(store.snapshot.oldestLoadedSequence, 1)
    XCTAssertEqual(store.snapshot.newestLoadedSequence, 3)
    XCTAssertFalse(store.snapshot.hasMoreHistoryBefore)
  }

  func testAppendReplaceRemoveAndClearKeepVisibleConversationStateCoherent() {
    let session = ScopedSessionID(endpointId: UUID(), sessionId: "session-2")
    var store = ConversationStructureStore(session: session)

    store.apply(.bootstrap(
      rows: [
        ConversationRowRecord(
          id: "message-1",
          session: session,
          kind: .message,
          payload: .message(.init(
            messageID: "message-1",
            role: .assistant,
            speaker: "Assistant",
            text: "one",
            timestamp: nil,
            contentSignature: 1
          )),
          sequence: 1
        ),
      ],
      oldestLoadedSequence: 1,
      newestLoadedSequence: 1,
      hasMoreHistoryBefore: true
    ))

    store.apply(.append(
      row: ConversationRowRecord(
        id: "worker-2",
        session: session,
        kind: .worker,
        payload: .worker(messageID: "message-2", workerID: "worker-1"),
        sequence: 2
      )
    ))
    store.apply(.replace(
      rowID: "worker-2",
      row: ConversationRowRecord(
        id: "worker-2",
        session: session,
        kind: .worker,
        payload: .worker(messageID: "message-2", workerID: "worker-1"),
        sequence: 2,
        revision: 1
      )
    ))
    store.apply(.remove(rowID: "message-1"))

    XCTAssertEqual(store.snapshot.rows.map(\.id), ["worker-2"])
    XCTAssertEqual(store.snapshot.rows.first?.revision, 1)
    XCTAssertEqual(store.snapshot.oldestLoadedSequence, 1)
    XCTAssertEqual(store.snapshot.newestLoadedSequence, 2)
    XCTAssertTrue(store.snapshot.hasMoreHistoryBefore)

    store.apply(.clear)

    XCTAssertTrue(store.snapshot.rows.isEmpty)
    XCTAssertNil(store.snapshot.oldestLoadedSequence)
    XCTAssertNil(store.snapshot.newestLoadedSequence)
    XCTAssertFalse(store.snapshot.hasMoreHistoryBefore)
  }
}
