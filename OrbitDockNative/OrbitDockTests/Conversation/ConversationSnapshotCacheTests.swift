import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct ConversationSnapshotCacheTests {
  private let endpointId = UUID()

  @Test func restoreFromCacheHydratesConversationState() throws {
    let store = ConversationStore(sessionId: "session-cache", endpointId: endpointId, clients: makeClients())
    let cached = CachedConversation(
      messages: [
        makeMessage(id: "msg-1", sequence: 10, type: .user, content: "Hello"),
        makeMessage(id: "msg-2", sequence: 11, type: .assistant, content: "Hi there"),
      ],
      totalMessageCount: 8,
      oldestSequence: 10,
      newestSequence: 11,
      hasMoreHistoryBefore: true,
      cachedAt: Date(timeIntervalSince1970: 500)
    )

    store.restoreFromCache(cached)

    #expect(store.messages.map(\TranscriptMessage.id) == ["msg-1", "msg-2"])
    #expect(store.totalMessageCount == 8)
    #expect(store.oldestLoadedSequence == 10)
    #expect(store.newestLoadedSequence == 11)
    #expect(store.hasMoreHistoryBefore)
    #expect(store.hasReceivedInitialData)
    #expect(store.hydrationState == ConversationHydrationState.readyPartial)
    #expect(store.hasRenderableConversation)
    #expect(store.messagesRevision == 1)
  }

  @Test func cacheSnapshotPreservesConversationWindow() throws {
    let store = ConversationStore(sessionId: "session-cache", endpointId: endpointId, clients: makeClients())
    let cachedAt = Date(timeIntervalSince1970: 800)
    store.restoreFromCache(
      CachedConversation(
        messages: [
          makeMessage(id: "msg-1", sequence: 21, type: .user, content: "One"),
          makeMessage(id: "msg-2", sequence: 22, type: .tool, content: "Run tests", toolName: "bash"),
          makeMessage(id: "msg-3", sequence: 23, type: .assistant, content: "Done"),
        ],
        totalMessageCount: 3,
        oldestSequence: 21,
        newestSequence: 23,
        hasMoreHistoryBefore: false,
        cachedAt: cachedAt
      )
    )

    let snapshot = store.cacheSnapshot()

    #expect(snapshot.messages.map(\TranscriptMessage.id) == ["msg-1", "msg-2", "msg-3"])
    #expect(snapshot.totalMessageCount == 3)
    #expect(snapshot.oldestSequence == 21)
    #expect(snapshot.newestSequence == 23)
    #expect(snapshot.hasMoreHistoryBefore == false)
    #expect(snapshot.cachedAt >= cachedAt)
    #expect(store.hydrationState == ConversationHydrationState.readyComplete)
  }

  @Test func restoreFromCacheCanBeClearedBackToEmptyState() throws {
    let store = ConversationStore(sessionId: "session-cache", endpointId: endpointId, clients: makeClients())
    store.restoreFromCache(
      CachedConversation(
        messages: [makeMessage(id: "msg-1", sequence: 1, type: .assistant, content: "cached")],
        totalMessageCount: 1,
        oldestSequence: 1,
        newestSequence: 1,
        hasMoreHistoryBefore: true,
        cachedAt: Date()
      )
    )

    store.clear()

    #expect(store.messages.isEmpty)
    #expect(store.totalMessageCount == 0)
    #expect(store.oldestLoadedSequence == nil)
    #expect(store.newestLoadedSequence == nil)
    #expect(store.hasMoreHistoryBefore == false)
    #expect(store.hasReceivedInitialData == false)
    #expect(store.hydrationState == ConversationHydrationState.empty)
  }

  @Test func contentOnlyStreamingUpdateUsesStreamingPatchRevision() async throws {
    let store = ConversationStore(sessionId: "session-cache", endpointId: endpointId, clients: makeClients())
    store.restoreFromCache(
      CachedConversation(
        messages: [
          makeMessage(id: "msg-1", sequence: 1, type: .assistant, content: "hello", isInProgress: true)
        ],
        totalMessageCount: 1,
        oldestSequence: 1,
        newestSequence: 1,
        hasMoreHistoryBefore: false,
        cachedAt: Date()
      )
    )

    let revisionBefore = store.messagesRevision
    let patchRevisionBefore = store.streamingPatchRevision

    store.handleMessageUpdated(
      messageId: "msg-1",
      changes: ServerMessageChanges(
        content: "hello there",
        toolOutput: nil,
        isError: nil,
        isInProgress: true,
        durationMs: nil
      )
    )
    await waitForStreamingPatch(
      store,
      expectedRevision: patchRevisionBefore + 1,
      expectedPatch: ConversationStreamingPatch(messageId: "msg-1")
    )

    #expect(store.messages.count == 1)
    #expect(store.messages.first?.content == "hello there")
    #expect(store.messages.first?.isInProgress == true)
    #expect(store.messagesRevision == revisionBefore)
    #expect(store.streamingPatchRevision == patchRevisionBefore + 1)
    #expect(store.latestStreamingPatch == ConversationStreamingPatch(messageId: "msg-1"))
  }

  @Test func completedStreamingUpdateStillBumpsStructuralRevision() throws {
    let store = ConversationStore(sessionId: "session-cache", endpointId: endpointId, clients: makeClients())
    store.restoreFromCache(
      CachedConversation(
        messages: [
          makeMessage(id: "msg-1", sequence: 1, type: .assistant, content: "hello", isInProgress: true)
        ],
        totalMessageCount: 1,
        oldestSequence: 1,
        newestSequence: 1,
        hasMoreHistoryBefore: false,
        cachedAt: Date()
      )
    )

    let revisionBefore = store.messagesRevision
    let patchRevisionBefore = store.streamingPatchRevision

    store.handleMessageUpdated(
      messageId: "msg-1",
      changes: ServerMessageChanges(
        content: "hello there",
        toolOutput: nil,
        isError: nil,
        isInProgress: false,
        durationMs: nil
      )
    )

    #expect(store.messages.count == 1)
    #expect(store.messages.first?.content == "hello there")
    #expect(store.messages.first?.isInProgress == false)
    #expect(store.messagesRevision == revisionBefore + 1)
    #expect(store.streamingPatchRevision == patchRevisionBefore)
    #expect(store.latestStreamingPatch == nil)
  }

  @Test func multipleStreamingUpdatesCoalesceIntoOnePatchPerMainActorTurn() async throws {
    let store = ConversationStore(sessionId: "session-cache", endpointId: endpointId, clients: makeClients())
    store.restoreFromCache(
      CachedConversation(
        messages: [
          makeMessage(id: "msg-1", sequence: 1, type: .assistant, content: "hello", isInProgress: true)
        ],
        totalMessageCount: 1,
        oldestSequence: 1,
        newestSequence: 1,
        hasMoreHistoryBefore: false,
        cachedAt: Date()
      )
    )

    let revisionBefore = store.messagesRevision
    let patchRevisionBefore = store.streamingPatchRevision

    store.handleMessageUpdated(
      messageId: "msg-1",
      changes: ServerMessageChanges(
        content: "hello there",
        toolOutput: nil,
        isError: nil,
        isInProgress: true,
        durationMs: nil
      )
    )
    store.handleMessageUpdated(
      messageId: "msg-1",
      changes: ServerMessageChanges(
        content: "hello there again",
        toolOutput: nil,
        isError: nil,
        isInProgress: true,
        durationMs: nil
      )
    )
    await waitForStreamingPatch(
      store,
      expectedRevision: patchRevisionBefore + 1,
      expectedPatch: ConversationStreamingPatch(messageId: "msg-1")
    )

    #expect(store.messages.first?.content == "hello there again")
    #expect(store.messagesRevision == revisionBefore)
    #expect(store.streamingPatchRevision == patchRevisionBefore + 1)
    #expect(store.latestStreamingPatch == ConversationStreamingPatch(messageId: "msg-1"))
  }

  private func makeClients() -> ServerClients {
    ServerClients(
      serverURL: URL(string: "http://127.0.0.1:4000")!,
      authToken: nil,
      dataLoader: { _ in
        Issue.record("ConversationSnapshotCacheTests should not hit the network.")
        throw ServerRequestError.notConnected
      }
    )
  }

  private func makeMessage(
    id: String,
    sequence: UInt64,
    type: TranscriptMessage.MessageType,
    content: String,
    toolName: String? = nil,
    isInProgress: Bool = false
  ) -> TranscriptMessage {
    TranscriptMessage(
      id: id,
      sequence: sequence,
      type: type,
      content: content,
      timestamp: Date(timeIntervalSince1970: TimeInterval(sequence)),
      toolName: toolName,
      isInProgress: isInProgress
    )
  }

  private func waitForStreamingPatch(
    _ store: ConversationStore,
    expectedRevision: Int,
    expectedPatch: ConversationStreamingPatch,
    maxTurns: Int = 10
  ) async {
    for _ in 0..<maxTurns {
      if store.streamingPatchRevision == expectedRevision,
         store.latestStreamingPatch == expectedPatch
      {
        return
      }
      await Task.yield()
    }
  }
}
