import Foundation

struct ConversationStreamingPatch: Sendable, Equatable {
  let messageId: String
}

enum StreamingPatchFlushOutcome: Sendable, Equatable {
  case none
  case patch(ConversationStreamingPatch, revision: Int)
  case structuralReset
}

enum StreamingMessageUpdateRoute: Sendable, Equatable {
  case streamingPatch(messageId: String)
  case structural
}

enum StreamingMessageEvent: Sendable, Equatable {
  case begin(messageID: String, content: String)
  case append(messageID: String, content: String, invalidatesHeight: Bool)
  case replace(messageID: String, content: String, invalidatesHeight: Bool)
  case finalize(messageID: String, content: String, invalidatesHeight: Bool)
  case remove(messageID: String)
  case clear
}

struct StreamingMessageRegistry: Sendable, Equatable {
  let session: ScopedSessionID
  private(set) var messagesByID: [String: StreamingMessageState] = [:]
  private(set) var pendingPatchMessageIDs: Set<String> = []
  private(set) var latestPatch: ConversationStreamingPatch?
  private(set) var revision: Int = 0

  init(session: ScopedSessionID) {
    self.session = session
  }

  init() {
    self.init(session: ScopedSessionID(endpointId: UUID(), sessionId: "legacy-conversation-store"))
  }

  mutating func apply(_ event: StreamingMessageEvent) {
    switch event {
      case let .begin(messageID, content):
        messagesByID[messageID] = StreamingMessageState(
          session: session,
          messageID: messageID,
          content: content
        )
        pendingPatchMessageIDs.insert(messageID)

      case let .append(messageID, content, invalidatesHeight):
        let existing = messagesByID[messageID]
        let nextContent = (existing?.content ?? "") + content
        messagesByID[messageID] = StreamingMessageState(
          session: session,
          messageID: messageID,
          content: nextContent,
          revision: (existing?.revision ?? 0) + 1,
          invalidatesHeight: invalidatesHeight || existing?.invalidatesHeight == true
        )
        pendingPatchMessageIDs.insert(messageID)

      case let .replace(messageID, content, invalidatesHeight):
        let existing = messagesByID[messageID]
        messagesByID[messageID] = StreamingMessageState(
          session: session,
          messageID: messageID,
          content: content,
          revision: (existing?.revision ?? 0) + 1,
          invalidatesHeight: invalidatesHeight
        )
        pendingPatchMessageIDs.insert(messageID)

      case let .finalize(messageID, content, invalidatesHeight):
        let existing = messagesByID[messageID]
        messagesByID[messageID] = StreamingMessageState(
          session: session,
          messageID: messageID,
          content: content,
          revision: (existing?.revision ?? 0) + 1,
          invalidatesHeight: invalidatesHeight,
          isFinal: true
        )
        pendingPatchMessageIDs.insert(messageID)

      case let .remove(messageID):
        messagesByID.removeValue(forKey: messageID)
        pendingPatchMessageIDs.remove(messageID)

      case .clear:
        messagesByID.removeAll(keepingCapacity: false)
        pendingPatchMessageIDs.removeAll(keepingCapacity: false)
        latestPatch = nil
        revision = 0
    }
  }

  mutating func drainPendingPatches() -> [StreamingMessageState] {
    let drained = pendingPatchMessageIDs.compactMap { messagesByID[$0] }.sorted { $0.messageID < $1.messageID }
    pendingPatchMessageIDs.removeAll(keepingCapacity: true)
    return drained
  }

  mutating func enqueuePatch(messageId: String) -> Bool {
    let wasEmpty = pendingPatchMessageIDs.isEmpty
    pendingPatchMessageIDs.insert(messageId)
    return wasEmpty
  }

  mutating func flushPendingPatches() -> StreamingPatchFlushOutcome {
    let messageIDs = pendingPatchMessageIDs.sorted()
    pendingPatchMessageIDs.removeAll(keepingCapacity: true)

    switch messageIDs.count {
      case 0:
        return .none
      case 1:
        let patch = ConversationStreamingPatch(messageId: messageIDs[0])
        latestPatch = patch
        revision += 1
        return .patch(patch, revision: revision)
      default:
        latestPatch = nil
        revision = 0
        return .structuralReset
    }
  }

  mutating func resetForStructuralChange() {
    pendingPatchMessageIDs.removeAll(keepingCapacity: false)
    latestPatch = nil
    revision = 0
  }

  static func classify(
    existing: TranscriptMessage,
    changes: ServerMessageChanges,
    messageId: String
  ) -> StreamingMessageUpdateRoute {
    guard existing.isInProgress,
          existing.type == .assistant || existing.type == .thinking,
          changes.isInProgress != false,
          changes.content != nil
    else {
      return .structural
    }

    return .streamingPatch(messageId: messageId)
  }
}
