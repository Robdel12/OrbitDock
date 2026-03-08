import Foundation
@testable import OrbitDock
import Testing

@MainActor
struct ConversationSnapshotCacheTests {
  @Test func cachedTranscriptMessageRoundTripsSequenceAndImages() throws {
    let original = TranscriptMessage(
      id: "msg-1",
      sequence: 17,
      type: .tool,
      content: "Run tests",
      timestamp: Date(timeIntervalSince1970: 1_234),
      toolName: "bash",
      toolInput: [
        "command": "npm test",
        "timeout_ms": 5_000,
      ],
      rawToolInput: #"{"command":"npm test"}"#,
      toolOutput: "ok",
      toolDuration: 1.5,
      inputTokens: 12,
      outputTokens: 34,
      isError: false,
      isInProgress: false,
      images: [
        MessageImage(
          id: "img-1",
          source: .filePath("/tmp/screenshot.png"),
          mimeType: "image/png",
          byteCount: 42
        )
      ],
      thinking: "Need to verify the failure first."
    )

    let cached = CachedTranscriptMessage(original)
    let data = try JSONEncoder().encode(cached)
    let decoded = try JSONDecoder().decode(CachedTranscriptMessage.self, from: data)
    let restored = decoded.transcriptMessage

    #expect(restored.id == original.id)
    #expect(restored.sequence == 17)
    #expect(restored.type == original.type)
    #expect(restored.toolName == original.toolName)
    #expect(restored.toolInput?["command"] as? String == "npm test")
    #expect(restored.toolInput?["timeout_ms"] as? Int == 5_000)
    #expect(restored.images.first?.id == "img-1")
    #expect(restored.images.first?.byteCount == 42)
    #expect(restored.thinking == original.thinking)
  }

  @Test func sqliteReadModelLoadsSavedConversationAndOlderPage() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let databaseURL = directory.appendingPathComponent("conversation-cache.sqlite", isDirectory: false)
    let store = ConversationReadModelStore(databaseURL: databaseURL, maxEntries: 10, maxAge: 3_600)
    let endpointId = UUID()
    let messages = [
      TranscriptMessage(
        id: "msg-1",
        sequence: 0,
        type: .user,
        content: "First",
        timestamp: Date(timeIntervalSince1970: 10)
      ),
      TranscriptMessage(
        id: "msg-2",
        sequence: 1,
        type: .assistant,
        content: "Second",
        timestamp: Date(timeIntervalSince1970: 20)
      ),
      TranscriptMessage(
        id: "msg-3",
        sequence: 2,
        type: .assistant,
        content: "Third",
        timestamp: Date(timeIntervalSince1970: 30)
      ),
    ]
    let metadata = CachedConversationMetadata(
      sessionId: "session-2",
      revision: 9,
      totalMessageCount: 3,
      oldestLoadedSequence: 0,
      newestLoadedSequence: 2,
      currentDiff: nil,
      currentPlan: nil,
      currentTurnId: nil,
      turnDiffs: [],
      tokenUsage: nil,
      tokenUsageSnapshotKind: .unknown,
      cachedAt: Date(timeIntervalSince1970: 2_000)
    )

    await store.save(
      endpointId: endpointId,
      sessionId: "session-2",
      metadata: metadata,
      messages: messages
    )

    let loaded = try #require(await store.loadConversation(
      endpointId: endpointId,
      sessionId: "session-2",
      limit: 2
    ))
    #expect(loaded.metadata.revision == 9)
    #expect(loaded.metadata.totalMessageCount == 3)
    #expect(loaded.messages.map(\.id) == ["msg-2", "msg-3"])

    let older = await store.loadMessagesBefore(
      endpointId: endpointId,
      sessionId: "session-2",
      beforeSequence: 1,
      limit: 2
    )
    #expect(older.map(\.id) == ["msg-1"])
  }

  @Test func sqliteReadModelPreservesOlderPagesWhenRefreshingNewestWindow() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let databaseURL = directory.appendingPathComponent("conversation-cache.sqlite", isDirectory: false)
    let store = ConversationReadModelStore(databaseURL: databaseURL, maxEntries: 10, maxAge: 3_600)
    let endpointId = UUID()

    let originalMessages = [
      TranscriptMessage(id: "msg-1", sequence: 0, type: .user, content: "One", timestamp: Date(timeIntervalSince1970: 10)),
      TranscriptMessage(id: "msg-2", sequence: 1, type: .assistant, content: "Two", timestamp: Date(timeIntervalSince1970: 20)),
      TranscriptMessage(id: "msg-3", sequence: 2, type: .assistant, content: "Three", timestamp: Date(timeIntervalSince1970: 30)),
      TranscriptMessage(id: "msg-4", sequence: 3, type: .assistant, content: "Four", timestamp: Date(timeIntervalSince1970: 40)),
    ]
    let originalMetadata = CachedConversationMetadata(
      sessionId: "session-3",
      revision: 10,
      totalMessageCount: 4,
      oldestLoadedSequence: 0,
      newestLoadedSequence: 3,
      currentDiff: nil,
      currentPlan: nil,
      currentTurnId: nil,
      turnDiffs: [],
      tokenUsage: nil,
      tokenUsageSnapshotKind: .unknown
    )

    await store.save(
      endpointId: endpointId,
      sessionId: "session-3",
      metadata: originalMetadata,
      messages: originalMessages
    )

    let refreshedWindow = [
      TranscriptMessage(id: "msg-3", sequence: 2, type: .assistant, content: "Three (updated)", timestamp: Date(timeIntervalSince1970: 30)),
      TranscriptMessage(id: "msg-4", sequence: 3, type: .assistant, content: "Four", timestamp: Date(timeIntervalSince1970: 40)),
      TranscriptMessage(id: "msg-5", sequence: 4, type: .assistant, content: "Five", timestamp: Date(timeIntervalSince1970: 50)),
    ]
    let refreshedMetadata = CachedConversationMetadata(
      sessionId: "session-3",
      revision: 11,
      totalMessageCount: 5,
      oldestLoadedSequence: 2,
      newestLoadedSequence: 4,
      currentDiff: nil,
      currentPlan: nil,
      currentTurnId: nil,
      turnDiffs: [],
      tokenUsage: nil,
      tokenUsageSnapshotKind: .unknown
    )

    await store.save(
      endpointId: endpointId,
      sessionId: "session-3",
      metadata: refreshedMetadata,
      messages: refreshedWindow
    )

    let latest = try #require(await store.loadConversation(
      endpointId: endpointId,
      sessionId: "session-3",
      limit: 3
    ))
    #expect(latest.metadata.totalMessageCount == 5)
    #expect(latest.messages.map(\.id) == ["msg-3", "msg-4", "msg-5"])
    #expect(latest.messages.first?.content == "Three (updated)")

    let older = await store.loadMessagesBefore(
      endpointId: endpointId,
      sessionId: "session-3",
      beforeSequence: 2,
      limit: 5
    )
    #expect(older.map(\.id) == ["msg-1", "msg-2"])
  }

  @Test func sqliteReadModelMetadataOnlyUpdateKeepsCachedMessages() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let databaseURL = directory.appendingPathComponent("conversation-cache.sqlite", isDirectory: false)
    let store = ConversationReadModelStore(databaseURL: databaseURL, maxEntries: 10, maxAge: 3_600)
    let endpointId = UUID()

    let messages = [
      TranscriptMessage(id: "msg-1", sequence: 0, type: .user, content: "One", timestamp: Date(timeIntervalSince1970: 10)),
      TranscriptMessage(id: "msg-2", sequence: 1, type: .assistant, content: "Two", timestamp: Date(timeIntervalSince1970: 20)),
    ]
    await store.save(
      endpointId: endpointId,
      sessionId: "session-4",
      metadata: CachedConversationMetadata(
        sessionId: "session-4",
        revision: 1,
        totalMessageCount: 2,
        oldestLoadedSequence: 0,
        newestLoadedSequence: 1,
        currentDiff: nil,
        currentPlan: nil,
        currentTurnId: nil,
        turnDiffs: [],
        tokenUsage: nil,
        tokenUsageSnapshotKind: .unknown
      ),
      messages: messages
    )

    await store.saveMetadata(
      endpointId: endpointId,
      sessionId: "session-4",
      metadata: CachedConversationMetadata(
        sessionId: "session-4",
        revision: 2,
        totalMessageCount: 2,
        oldestLoadedSequence: 0,
        newestLoadedSequence: 1,
        currentDiff: "diff",
        currentPlan: "plan",
        currentTurnId: "turn-1",
        turnDiffs: [],
        tokenUsage: nil,
        tokenUsageSnapshotKind: .unknown
      )
    )

    let loaded = try #require(await store.loadConversation(
      endpointId: endpointId,
      sessionId: "session-4",
      limit: 10
    ))
    #expect(loaded.metadata.revision == 2)
    #expect(loaded.metadata.currentDiff == "diff")
    #expect(loaded.messages.map(\.id) == ["msg-1", "msg-2"])
  }
}
