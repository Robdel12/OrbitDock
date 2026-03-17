import Foundation
@testable import OrbitDock
import Testing

@Suite("ConversationStructureStore")
@MainActor
struct ConversationStructureStoreTests {
  @Test func bootstrapAndPrependPreserveOrderedRows() {
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

    #expect(store.snapshot.rows.map { $0.id } == ["message-1", "message-2", "message-3"])
    #expect(store.snapshot.oldestLoadedSequence == 1)
    #expect(store.snapshot.newestLoadedSequence == 3)
    #expect(store.snapshot.hasMoreHistoryBefore == false)
  }

  @Test func appendReplaceRemoveAndClearKeepVisibleConversationStateCoherent() {
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

    #expect(store.snapshot.rows.map { $0.id } == ["worker-2"])
    #expect(store.snapshot.rows.first?.revision == 1)
    #expect(store.snapshot.oldestLoadedSequence == 1)
    #expect(store.snapshot.newestLoadedSequence == 2)
    #expect(store.snapshot.hasMoreHistoryBefore == true)

    store.apply(.clear)

    #expect(store.snapshot.rows.isEmpty)
    #expect(store.snapshot.oldestLoadedSequence == nil)
    #expect(store.snapshot.newestLoadedSequence == nil)
    #expect(store.snapshot.hasMoreHistoryBefore == false)
  }
}
