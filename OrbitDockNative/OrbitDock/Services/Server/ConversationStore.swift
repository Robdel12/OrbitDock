//
//  ConversationStore.swift
//  OrbitDock
//
//  Per-session conversation state: messages, pagination, normalization.
//  Owns all conversation data loading via typed server clients (HTTP).
//  Receives live updates from EventStream events (pushed by SessionStore).
//

import Foundation

private let kPageSize = 50
private let kBootstrapMinTurns = 4
private let kBootstrapMaxMessages = 200

enum ConversationRecoveryGoal: Sendable, Equatable {
  case coherentRecent
  case completeHistory

  nonisolated static func == (lhs: ConversationRecoveryGoal, rhs: ConversationRecoveryGoal) -> Bool {
    switch (lhs, rhs) {
      case (.coherentRecent, .coherentRecent),
           (.completeHistory, .completeHistory):
        true
      default:
        false
    }
  }
}

enum ConversationHydrationState: Sendable, Equatable {
  case empty
  case loadingRecent
  case readyPartial
  case readyComplete
  case failed

  var hasRenderableConversation: Bool {
    switch self {
      case .readyPartial, .readyComplete:
        return true
      case .empty, .loadingRecent, .failed:
        return false
    }
  }
}

func requiresConversationBootstrapBackfill(
  messages: [TranscriptMessage],
  hasMoreHistoryBefore: Bool,
  minimumTurnCount: Int
) -> Bool {
  guard hasMoreHistoryBefore else { return false }

  let turnCount = messages.filter { $0.type == .user }.count
  if turnCount < minimumTurnCount { return true }

  if let first = messages.first, first.type != .user { return true }

  return false
}

// MARK: - ConversationStore

@Observable
@MainActor
final class ConversationStore {
  let sessionId: String
  let endpointId: UUID
  private let clients: ServerClients

  // MARK: - Observable state

  private(set) var messages: [TranscriptMessage] = []
  private(set) var messagesRevision: Int = 0
  private(set) var streamingPatchRevision: Int = 0
  private(set) var latestStreamingPatch: ConversationStreamingPatch?
  private var pendingStreamingPatchFlushTask: Task<Void, Never>?
  private var streamingRegistry = StreamingMessageRegistry()
  private var normalizedMessagesCache: [TranscriptMessage] = []
  private var normalizedMessagesRevision: Int = -1
  private var normalizedMessagesStreamingRevision: Int = -1
  private(set) var totalMessageCount: Int = 0
  private(set) var oldestLoadedSequence: UInt64?
  private(set) var newestLoadedSequence: UInt64?
  private(set) var hasMoreHistoryBefore: Bool = false
  private(set) var isLoadingOlderMessages: Bool = false
  private(set) var hasReceivedInitialData: Bool = false
  private(set) var hydrationState: ConversationHydrationState = .empty
  private(set) var lastHydrationGoal: ConversationRecoveryGoal = .coherentRecent

  private var backfillTask: Task<Void, Never>?

  var hasRenderableConversation: Bool {
    hydrationState.hasRenderableConversation
  }

  var isFullyHydrated: Bool {
    hydrationState == .readyComplete
  }

  var normalizedMessages: [TranscriptMessage] {
    if normalizedMessagesRevision == messagesRevision,
       normalizedMessagesStreamingRevision == streamingPatchRevision
    {
      return normalizedMessagesCache
    }

    normalizedMessagesCache = ConversationRenderMessageNormalizer.normalize(
      messages,
      sessionId: sessionId,
      source: "conversation-store"
    )
    normalizedMessagesRevision = messagesRevision
    normalizedMessagesStreamingRevision = streamingPatchRevision
    return normalizedMessagesCache
  }

  init(sessionId: String, endpointId: UUID, clients: ServerClients) {
    self.sessionId = sessionId
    self.endpointId = endpointId
    self.clients = clients
  }

  var serverClients: ServerClients {
    clients
  }

  // MARK: - Bootstrap (initial load from HTTP)

  /// Load the newest conversation page from the server.
  /// Returns the bootstrap's revision for WS subscription.
  func bootstrap(goal: ConversationRecoveryGoal = .coherentRecent) async -> UInt64? {
    let result = await bootstrapSnapshot(goal: goal)
    return result?.session.revision
  }

  /// Load the newest conversation page from the server and return the full
  /// bootstrap payload so callers can hydrate session-level state without
  /// issuing a second full-session request.
  func bootstrapSnapshot(goal: ConversationRecoveryGoal = .coherentRecent) async -> ServerConversationBootstrap? {
    netLog(.info, cat: .conv, "Bootstrapping", sid: self.sessionId)
    lastHydrationGoal = goal
    if !hydrationState.hasRenderableConversation {
      hydrationState = .loadingRecent
    }
    do {
      let result = try await clients.conversation.fetchConversationBootstrap(sessionId, limit: kPageSize)
      applyBootstrap(result, goal: goal)
      netLog(.info, cat: .conv, "Bootstrap complete", sid: self.sessionId, data: ["messages": self.messages.count, "revision": result.session.revision ?? 0])
      return result
    } catch {
      hydrationState = messages.isEmpty ? .failed : .readyPartial
      netLog(.error, cat: .conv, "Bootstrap failed", sid: self.sessionId, data: ["error": error.localizedDescription])
      return nil
    }
  }

  /// Wait for any in-flight recovery pass to settle.
  /// Useful for deterministic tests and recovery flows that need the final
  /// hydrated state rather than just the initial recent window.
  func waitForHydrationToSettle() async {
    let task = backfillTask
    await task?.value
  }

  /// Restore from a cached snapshot for instant session switching.
  func restoreFromCache(_ cached: CachedConversation) {
    messages = cached.messages
    totalMessageCount = cached.totalMessageCount
    oldestLoadedSequence = cached.oldestSequence
    newestLoadedSequence = cached.newestSequence
    hasMoreHistoryBefore = cached.hasMoreHistoryBefore
    hasReceivedInitialData = true
    hydrationState = cached.hasMoreHistoryBefore ? .readyPartial : .readyComplete
    bumpRevision()
    netLog(.info, cat: .conv, "Restored from cache", sid: self.sessionId, data: ["messages": cached.messages.count])
  }

  /// Take a snapshot for caching before the store is trimmed.
  func cacheSnapshot() -> CachedConversation {
    CachedConversation(
      messages: messages,
      totalMessageCount: totalMessageCount,
      oldestSequence: oldestLoadedSequence,
      newestSequence: newestLoadedSequence,
      hasMoreHistoryBefore: hasMoreHistoryBefore,
      cachedAt: Date()
    )
  }

  // MARK: - Pagination (load older messages)

  func loadOlderMessages(limit: Int = 50) {
    guard !isLoadingOlderMessages, hasMoreHistoryBefore,
          let before = oldestLoadedSequence
    else { return }

    isLoadingOlderMessages = true
    netLog(.info, cat: .conv, "Loading older messages", sid: self.sessionId, data: ["beforeSeq": before])

    Task {
      defer { isLoadingOlderMessages = false }
      do {
        let page = try await clients.conversation.fetchConversationHistory(
          sessionId, beforeSequence: before, limit: limit)
        applyHistoryPage(page)
      } catch {
        netLog(.error, cat: .conv, "Load older messages failed", sid: self.sessionId, data: ["error": error.localizedDescription])
      }
    }
  }

  // MARK: - Live event handlers (called by SessionStore)

  func handleConversationBootstrap(session: ServerSessionState, conversation: ServerConversationHistoryPage) {
    applyRowsPage(conversation.rows, totalRowCount: conversation.totalRowCount, hasMoreBefore: conversation.hasMoreBefore, oldestSequence: conversation.oldestSequence, newestSequence: conversation.newestSequence, goal: lastHydrationGoal, preserveOlderMessages: true)
    hasReceivedInitialData = true
    if session.rows.isEmpty == false {
      newestLoadedSequence = max(newestLoadedSequence ?? 0, session.rows.last?.sequence ?? 0)
    }
  }

  func handleConversationRowsChanged(
    upserted: [ServerConversationRowEntry],
    removedRowIds: [String],
    totalRowCount: UInt64?
  ) {
    guard !upserted.isEmpty || !removedRowIds.isEmpty || totalRowCount != nil else { return }

    var nextMessages = messages
    let messageIDs = Dictionary(uniqueKeysWithValues: nextMessages.enumerated().map { ($1.id, $0) })

    for row in upserted {
      let normalized = normalizeMessage(row.toTranscriptMessage(endpointId: endpointId))
      if let existingIndex = messageIDs[normalized.id] {
        nextMessages[existingIndex] = mergeMessage(nextMessages[existingIndex], with: normalized)
      } else {
        nextMessages.append(normalized)
      }
    }

    if !removedRowIds.isEmpty {
      let removed = Set(removedRowIds)
      nextMessages.removeAll { removed.contains($0.id) }
    }

    nextMessages.sort { lhs, rhs in
      switch (lhs.sequence, rhs.sequence) {
        case let (l?, r?):
          return l < r
        case (.some, .none):
          return true
        case (.none, .some):
          return false
        case (.none, .none):
          return lhs.timestamp < rhs.timestamp
      }
    }

    messages = nextMessages
    self.totalMessageCount = totalRowCount.map(Int.init) ?? max(self.totalMessageCount, messages.count)
    oldestLoadedSequence = messages.compactMap(\.sequence).min()
    newestLoadedSequence = messages.compactMap(\.sequence).max()
    hasReceivedInitialData = true
    hydrationState = shouldContinueRecovering(for: lastHydrationGoal) ? .readyPartial : .readyComplete
    bumpRevision()
  }

  /// Re-fetch the full conversation from HTTP after a lagged/overflow event.
  func handleLagged() {
    netLog(.warning, cat: .conv, "Lagged event — re-bootstrapping", sid: self.sessionId)
    backfillTask?.cancel()
    Task {
      _ = await bootstrap(goal: .coherentRecent)
    }
  }

  /// Cancel any in-flight work and re-bootstrap, awaitable by the caller.
  func bootstrapFresh() async {
    netLog(.warning, cat: .conv, "Fresh bootstrap requested", sid: self.sessionId)
    backfillTask?.cancel()
    _ = await bootstrap(goal: .coherentRecent)
  }

  /// Clear all message data (e.g. on disconnect).
  func clear() {
    backfillTask?.cancel()
    messages = []
    totalMessageCount = 0
    oldestLoadedSequence = nil
    newestLoadedSequence = nil
    hasMoreHistoryBefore = false
    hasReceivedInitialData = false
    hydrationState = .empty
    bumpRevision()
    netLog(.info, cat: .conv, "Cleared conversation", sid: self.sessionId)
  }

  // MARK: - Private

  private func applyBootstrap(_ bootstrap: ServerConversationBootstrap, goal: ConversationRecoveryGoal) {
    applyRowsPage(
      bootstrap.rows,
      totalRowCount: bootstrap.totalRowCount,
      hasMoreBefore: bootstrap.hasMoreBefore,
      oldestSequence: bootstrap.oldestSequence,
      newestSequence: bootstrap.newestSequence,
      goal: goal,
      preserveOlderMessages: true
    )
  }

  private func applyHistoryPage(_ page: ServerConversationHistoryPage) {
    let beforeCount = messages.count
    applyRowsPage(
      page.rows,
      totalRowCount: page.totalRowCount,
      hasMoreBefore: page.hasMoreBefore,
      oldestSequence: page.oldestSequence,
      newestSequence: page.newestSequence,
      goal: lastHydrationGoal,
      preserveOlderMessages: false
    )
    netLog(.debug, cat: .conv, "Applied history page", sid: self.sessionId, data: ["added": messages.count - beforeCount, "total": self.messages.count])
  }

  private func scheduleBackfillIfNeeded() {
    backfillTask?.cancel()
    guard shouldContinueRecovering(for: lastHydrationGoal) else { return }
    backfillTask = Task {
      await backfillIfNeeded()
    }
  }

  private func backfillIfNeeded() async {
    defer { backfillTask = nil }
    while !Task.isCancelled, shouldContinueRecovering(for: lastHydrationGoal) {
      guard let before = oldestLoadedSequence else { break }
      netLog(.debug, cat: .conv, "Backfill page", sid: self.sessionId, data: ["beforeSeq": before])
      do {
        let page = try await clients.conversation.fetchConversationHistory(
          sessionId, beforeSequence: before, limit: kPageSize)
        let countBefore = messages.count
        applyHistoryPage(page)
        // Stop if no new messages were added (prevents infinite loop)
        guard messages.count > countBefore else { break }
      } catch {
        hydrationState = messages.isEmpty ? .failed : .readyPartial
        netLog(.error, cat: .conv, "Backfill page failed", sid: self.sessionId, data: ["error": error.localizedDescription])
        break
      }
    }
  }

  private func shouldContinueRecovering(for goal: ConversationRecoveryGoal) -> Bool {
    guard hasMoreHistoryBefore else { return false }

    switch goal {
      case .coherentRecent:
        guard messages.count < kBootstrapMaxMessages else { return false }
        return requiresConversationBootstrapBackfill(
          messages: messages,
          hasMoreHistoryBefore: hasMoreHistoryBefore,
          minimumTurnCount: kBootstrapMinTurns
        )
      case .completeHistory:
        return true
    }
  }

  private func bumpRevision() {
    streamingRegistry.resetForStructuralChange()
    pendingStreamingPatchFlushTask?.cancel()
    pendingStreamingPatchFlushTask = nil
    latestStreamingPatch = streamingRegistry.latestPatch
    messagesRevision += 1
  }

  // MARK: - Normalization

  private func normalizeMessages(_ incoming: [TranscriptMessage]) -> [TranscriptMessage] {
    guard !incoming.isEmpty else { return [] }
    var result: [TranscriptMessage] = []
    result.reserveCapacity(incoming.count)
    var indexByID: [String: Int] = [:]

    for raw in incoming {
      let id = raw.id.trimmingCharacters(in: .whitespacesAndNewlines)
      let messageID = id.isEmpty ? "\(sessionId):synthetic:\(result.count)" : id

      let msg = messageID == raw.id ? raw : withMessageID(raw, id: messageID)

      if let existingIdx = indexByID[messageID] {
        result[existingIdx] = mergeMessage(result[existingIdx], with: msg)
      } else {
        indexByID[messageID] = result.count
        result.append(msg)
      }
    }
    return result
  }

  private func applyRowsPage(
    _ rows: [ServerConversationRowEntry],
    totalRowCount: UInt64,
    hasMoreBefore: Bool,
    oldestSequence: UInt64?,
    newestSequence: UInt64?,
    goal: ConversationRecoveryGoal,
    preserveOlderMessages: Bool
  ) {
    let incoming = normalizeMessages(rows.map { $0.toTranscriptMessage(endpointId: endpointId) })

    var preserved: [TranscriptMessage] = []
    if preserveOlderMessages,
       let bootstrapOldest = oldestSequence,
       let existingOldest = oldestLoadedSequence,
       existingOldest < bootstrapOldest
    {
      preserved = messages.filter { msg in
        guard let seq = msg.sequence else { return false }
        return seq < bootstrapOldest
      }
    }

    let merged = normalizeMessages(preserved + incoming + (preserveOlderMessages ? [] : messages))
      .sorted { lhs, rhs in
        switch (lhs.sequence, rhs.sequence) {
          case let (l?, r?):
            return l < r
          case (.some, .none):
            return true
          case (.none, .some):
            return false
          case (.none, .none):
            return lhs.timestamp < rhs.timestamp
        }
      }

    messages = merged
    totalMessageCount = max(Int(totalRowCount), messages.count)
    self.oldestLoadedSequence = oldestSequence ?? messages.compactMap(\.sequence).min()
    self.newestLoadedSequence = newestSequence ?? messages.compactMap(\.sequence).max()
    hasMoreHistoryBefore = preserveOlderMessages ? (preserved.isEmpty ? hasMoreBefore : true) : hasMoreBefore
    hasReceivedInitialData = true
    hydrationState = shouldContinueRecovering(for: goal) ? .readyPartial : .readyComplete
    bumpRevision()
    scheduleBackfillIfNeeded()
  }

  private func normalizeMessage(_ msg: TranscriptMessage) -> TranscriptMessage {
    let id = msg.id.trimmingCharacters(in: .whitespacesAndNewlines)
    if id.isEmpty {
      return withMessageID(msg, id: "\(sessionId):synthetic:\(messages.count)")
    }
    return id == msg.id ? msg : withMessageID(msg, id: id)
  }

  private func withMessageID(_ msg: TranscriptMessage, id: String) -> TranscriptMessage {
    TranscriptMessage(
      id: id,
      sequence: msg.sequence,
      type: msg.type,
      content: msg.content,
      timestamp: msg.timestamp,
      toolName: msg.toolName,
      toolInput: msg.toolInput,
      rawToolInput: msg.rawToolInput,
      toolOutput: msg.toolOutput,
      toolDuration: msg.toolDuration,
      inputTokens: msg.inputTokens,
      outputTokens: msg.outputTokens,
      isError: msg.isError,
      isInProgress: msg.isInProgress,
      images: msg.images,
      thinking: msg.thinking
    )
  }

  private func mergeMessage(
    _ existing: TranscriptMessage, with incoming: TranscriptMessage
  ) -> TranscriptMessage {
    TranscriptMessage(
      id: existing.id,
      sequence: incoming.sequence ?? existing.sequence,
      type: incoming.type,
      content: incoming.content.isEmpty ? existing.content : incoming.content,
      timestamp: incoming.timestamp,
      toolName: incoming.toolName ?? existing.toolName,
      toolInput: incoming.toolInput ?? existing.toolInput,
      rawToolInput: incoming.rawToolInput ?? existing.rawToolInput,
      toolOutput: incoming.toolOutput ?? existing.toolOutput,
      toolDuration: incoming.toolDuration ?? existing.toolDuration,
      inputTokens: incoming.inputTokens ?? existing.inputTokens,
      outputTokens: incoming.outputTokens ?? existing.outputTokens,
      isError: incoming.isError,
      isInProgress: incoming.isInProgress,
      images: incoming.images.isEmpty ? existing.images : incoming.images,
      thinking: incoming.thinking ?? existing.thinking
    )
  }
}

// MARK: - Cache Snapshot

struct CachedConversation {
  let messages: [TranscriptMessage]
  let totalMessageCount: Int
  let oldestSequence: UInt64?
  let newestSequence: UInt64?
  let hasMoreHistoryBefore: Bool
  var cachedAt: Date
}
