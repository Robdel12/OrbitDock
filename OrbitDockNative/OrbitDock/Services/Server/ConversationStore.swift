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

  func handleMessageAppended(_ serverMessage: ServerMessage) {
    let incoming = serverMessage.toTranscriptMessage(endpointId: endpointId)
    let normalized = normalizeMessage(incoming)

    if let existingIdx = messages.firstIndex(where: { $0.id == normalized.id }) {
      // Merge: update existing message
      messages[existingIdx] = mergeMessage(messages[existingIdx], with: normalized)
      totalMessageCount = max(totalMessageCount, messages.count)
      netLog(.debug, cat: .conv, "Message merged", sid: self.sessionId, data: ["messageId": normalized.id])
    } else {
      // Append
      messages.append(normalized)
      totalMessageCount = max(totalMessageCount + 1, messages.count)
      netLog(.debug, cat: .conv, "Message appended", sid: self.sessionId, data: ["messageId": normalized.id, "total": self.messages.count])
    }

    updateSequenceCursors(for: normalized)
    bumpRevision()
  }

  func handleMessageUpdated(messageId: String, changes: ServerMessageChanges) {
    guard let idx = messages.firstIndex(where: { $0.id == messageId }) else {
      // Upsert fallback: if we have content, create a synthetic message
      netLog(.warning, cat: .conv, "Upsert fallback — creating synthetic", sid: self.sessionId, data: ["messageId": messageId])
      if let content = changes.content {
        let synthetic = TranscriptMessage(
          id: messageId,
          sequence: nil,
          type: .assistant,
          content: content,
          timestamp: Date(),
          toolName: nil,
          toolInput: nil,
          rawToolInput: nil,
          toolOutput: nil,
          toolDuration: nil,
          inputTokens: nil,
          outputTokens: nil,
          isError: false,
          isInProgress: changes.isInProgress ?? false,
          images: [],
          thinking: nil
        )
        messages.append(synthetic)
        totalMessageCount = max(totalMessageCount + 1, messages.count)
        bumpRevision()
      }
      return
    }

    var msg = messages[idx]

    if let content = changes.content {
      msg = TranscriptMessage(
        id: msg.id,
        sequence: msg.sequence,
        type: msg.type,
        content: content,
        timestamp: msg.timestamp,
        toolName: msg.toolName,
        toolInput: msg.toolInput,
        rawToolInput: msg.rawToolInput,
        toolOutput: changes.toolOutput ?? msg.toolOutput,
        toolDuration: changes.durationMs.map { Double($0) / 1_000.0 } ?? msg.toolDuration,
        inputTokens: msg.inputTokens,
        outputTokens: msg.outputTokens,
        isError: changes.isError ?? msg.isError,
        isInProgress: changes.isInProgress ?? msg.isInProgress,
        images: msg.images,
        thinking: msg.thinking,
        toolDisplay: changes.toolDisplay ?? msg.toolDisplay
      )
    } else {
      if let toolOutput = changes.toolOutput { msg.toolOutput = toolOutput }
      if let durationMs = changes.durationMs { msg.toolDuration = Double(durationMs) / 1_000.0 }
      if let isError = changes.isError { msg.isError = isError }
      if let isInProgress = changes.isInProgress { msg.isInProgress = isInProgress }
      if let toolDisplay = changes.toolDisplay { msg.toolDisplay = toolDisplay }
    }

    let updateRoute = StreamingMessageRegistry.classify(
      existing: messages[idx],
      changes: changes,
      messageId: messageId
    )
    messages[idx] = msg
    if case .streamingPatch = updateRoute {
      scheduleStreamingPatch(messageId: messageId)
    } else {
      bumpRevision()
    }
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
    let incoming = bootstrap.session.messages.map { $0.toTranscriptMessage(endpointId: endpointId) }
    let normalized = normalizeMessages(incoming)

    // If we already have messages, check if the bootstrap supersedes them
    let existingOldest = oldestLoadedSequence
    let bootstrapOldest = bootstrap.oldestSequence

    // Preserve any older messages we already have that the bootstrap doesn't cover
    var preserved: [TranscriptMessage] = []
    if let bOldest = bootstrapOldest, let eOldest = existingOldest, eOldest < bOldest {
      preserved = messages.filter { msg in
        guard let seq = msg.sequence else { return false }
        return seq < bOldest
      }
    }

    messages = preserved + normalized
    totalMessageCount = max(Int(bootstrap.totalMessageCount), messages.count)
    oldestLoadedSequence = preserved.first?.sequence ?? bootstrap.oldestSequence
    newestLoadedSequence = bootstrap.newestSequence
    hasMoreHistoryBefore = preserved.isEmpty ? bootstrap.hasMoreBefore : true
    hasReceivedInitialData = true
    hydrationState = shouldContinueRecovering(for: goal) ? .readyPartial : .readyComplete
    bumpRevision()
    scheduleBackfillIfNeeded()
  }

  private func applyHistoryPage(_ page: ServerConversationHistoryPage) {
    let incoming = page.messages.map { $0.toTranscriptMessage(endpointId: endpointId) }
    let normalized = normalizeMessages(incoming)
    guard !normalized.isEmpty else { return }

    // Prepend older messages, deduplicating by ID
    let existingIDs = Set(messages.map(\.id))
    let newMessages = normalized.filter { !existingIDs.contains($0.id) }
    messages = newMessages + messages

    totalMessageCount = max(Int(page.totalMessageCount), messages.count)
    oldestLoadedSequence = page.oldestSequence ?? oldestLoadedSequence
    if let pageNewest = page.newestSequence {
      if let currentNewest = newestLoadedSequence {
        newestLoadedSequence = max(currentNewest, pageNewest)
      } else {
        newestLoadedSequence = pageNewest
      }
    }
    hasMoreHistoryBefore = page.hasMoreBefore
    hydrationState = shouldContinueRecovering(for: lastHydrationGoal) ? .readyPartial : .readyComplete
    bumpRevision()
    netLog(.debug, cat: .conv, "Applied history page", sid: self.sessionId, data: ["added": newMessages.count, "total": self.messages.count])
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

  private func updateSequenceCursors(for message: TranscriptMessage) {
    if let seq = message.sequence {
      if let current = newestLoadedSequence {
        newestLoadedSequence = max(current, seq)
      } else {
        newestLoadedSequence = seq
      }
      if oldestLoadedSequence == nil {
        oldestLoadedSequence = seq
      }
    }
  }

  private func bumpRevision() {
    streamingRegistry.resetForStructuralChange()
    pendingStreamingPatchFlushTask?.cancel()
    pendingStreamingPatchFlushTask = nil
    latestStreamingPatch = streamingRegistry.latestPatch
    messagesRevision += 1
  }

  private func scheduleStreamingPatch(messageId: String) {
    let shouldSchedule = streamingRegistry.enqueuePatch(messageId: messageId)
    guard shouldSchedule, pendingStreamingPatchFlushTask == nil else { return }
    pendingStreamingPatchFlushTask = Task { @MainActor [weak self] in
      await Task.yield()
      self?.flushPendingStreamingPatches()
    }
  }

  private func flushPendingStreamingPatches() {
    pendingStreamingPatchFlushTask = nil
    switch streamingRegistry.flushPendingPatches() {
      case .none:
        return
      case let .patch(patch, revision):
        latestStreamingPatch = patch
        streamingPatchRevision = revision
      case .structuralReset:
        bumpRevision()
    }
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
