//
//  ConversationStore.swift
//  OrbitDock
//
//  Per-session conversation state: messages, pagination, normalization.
//  Owns all conversation data loading via APIClient (HTTP).
//  Receives live updates from EventStream events (pushed by SessionStore).
//

import Foundation

private let kPageSize = 50
private let kBootstrapMinTurns = 4
private let kBootstrapMaxMessages = 200

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
  private let apiClient: APIClient

  // MARK: - Observable state

  private(set) var messages: [TranscriptMessage] = []
  private(set) var messagesRevision: Int = 0
  private(set) var totalMessageCount: Int = 0
  private(set) var oldestLoadedSequence: UInt64?
  private(set) var newestLoadedSequence: UInt64?
  private(set) var hasMoreHistoryBefore: Bool = false
  private(set) var isLoadingOlderMessages: Bool = false
  private(set) var hasReceivedInitialData: Bool = false

  private var backfillTask: Task<Void, Never>?

  init(sessionId: String, apiClient: APIClient) {
    self.sessionId = sessionId
    self.apiClient = apiClient
  }

  // MARK: - Bootstrap (initial load from HTTP)

  /// Load the newest conversation page from the server.
  /// Returns the bootstrap's revision for WS subscription.
  func bootstrap() async -> UInt64? {
    netLog(.info, cat: .conv, "Bootstrapping", sid: self.sessionId)
    do {
      let result = try await apiClient.fetchConversationBootstrap(sessionId, limit: kPageSize)
      applyBootstrap(result)
      netLog(.info, cat: .conv, "Bootstrap complete", sid: self.sessionId, data: ["messages": self.messages.count, "revision": result.session.revision ?? 0])
      scheduleBackfill()
      return result.session.revision
    } catch {
      netLog(.error, cat: .conv, "Bootstrap failed", sid: self.sessionId, data: ["error": error.localizedDescription])
      return nil
    }
  }

  /// Restore from a cached snapshot for instant session switching.
  func restoreFromCache(_ cached: CachedConversation) {
    messages = cached.messages
    totalMessageCount = cached.totalMessageCount
    oldestLoadedSequence = cached.oldestSequence
    newestLoadedSequence = cached.newestSequence
    hasMoreHistoryBefore = cached.hasMoreHistoryBefore
    hasReceivedInitialData = true
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
        let page = try await apiClient.fetchConversationHistory(
          sessionId, beforeSequence: before, limit: limit)
        applyHistoryPage(page)
      } catch {
        netLog(.error, cat: .conv, "Load older messages failed", sid: self.sessionId, data: ["error": error.localizedDescription])
      }
    }
  }

  // MARK: - Live event handlers (called by SessionStore)

  func handleMessageAppended(_ serverMessage: ServerMessage) {
    let incoming = serverMessage.toTranscriptMessage()
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
        thinking: msg.thinking
      )
    } else {
      if let toolOutput = changes.toolOutput { msg.toolOutput = toolOutput }
      if let durationMs = changes.durationMs { msg.toolDuration = Double(durationMs) / 1_000.0 }
      if let isError = changes.isError { msg.isError = isError }
      if let isInProgress = changes.isInProgress { msg.isInProgress = isInProgress }
    }

    messages[idx] = msg
    bumpRevision()
  }

  /// Re-fetch the full conversation from HTTP after a lagged/overflow event.
  func handleLagged() {
    netLog(.warning, cat: .conv, "Lagged event — re-bootstrapping", sid: self.sessionId)
    backfillTask?.cancel()
    Task {
      _ = await bootstrap()
    }
  }

  /// Cancel any in-flight work and re-bootstrap, awaitable by the caller.
  func bootstrapFresh() async {
    netLog(.warning, cat: .conv, "Fresh bootstrap requested", sid: self.sessionId)
    backfillTask?.cancel()
    _ = await bootstrap()
  }

  /// Handle session snapshot by replacing messages entirely.
  func handleSnapshot(_ state: ServerSessionState) {
    let incoming = state.messages.map { $0.toTranscriptMessage() }
    let normalized = normalizeMessages(incoming)

    messages = normalized
    totalMessageCount = max(Int(state.totalMessageCount ?? 0), normalized.count)
    oldestLoadedSequence = state.oldestSequence
    newestLoadedSequence = state.newestSequence
    hasMoreHistoryBefore = state.hasMoreBefore ?? false
    hasReceivedInitialData = true
    bumpRevision()
    netLog(.info, cat: .conv, "Snapshot received", sid: self.sessionId, data: ["messages": normalized.count])
    scheduleBackfill()
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
    bumpRevision()
    netLog(.info, cat: .conv, "Cleared conversation", sid: self.sessionId)
  }

  // MARK: - Private

  private func applyBootstrap(_ bootstrap: ServerConversationBootstrap) {
    let incoming = bootstrap.session.messages.map { $0.toTranscriptMessage() }
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
    bumpRevision()
  }

  private func applyHistoryPage(_ page: ServerConversationHistoryPage) {
    let incoming = page.messages.map { $0.toTranscriptMessage() }
    let normalized = normalizeMessages(incoming)
    guard !normalized.isEmpty else { return }

    // Prepend older messages, deduplicating by ID
    let existingIDs = Set(messages.map(\.id))
    let newMessages = normalized.filter { !existingIDs.contains($0.id) }
    messages = newMessages + messages

    totalMessageCount = max(Int(page.totalMessageCount), messages.count)
    oldestLoadedSequence = page.oldestSequence ?? oldestLoadedSequence
    newestLoadedSequence = page.newestSequence ?? newestLoadedSequence
    hasMoreHistoryBefore = page.hasMoreBefore
    bumpRevision()
    netLog(.debug, cat: .conv, "Applied history page", sid: self.sessionId, data: ["added": newMessages.count, "total": self.messages.count])
  }

  private func scheduleBackfill() {
    backfillTask?.cancel()
    backfillTask = Task {
      await backfillIfNeeded()
    }
  }

  private func backfillIfNeeded() async {
    while !Task.isCancelled,
          hasMoreHistoryBefore,
          messages.count < kBootstrapMaxMessages,
          requiresBackfill()
    {
      guard let before = oldestLoadedSequence else { break }
      netLog(.debug, cat: .conv, "Backfill page", sid: self.sessionId, data: ["beforeSeq": before])
      do {
        let page = try await apiClient.fetchConversationHistory(
          sessionId, beforeSequence: before, limit: kPageSize)
        let countBefore = messages.count
        applyHistoryPage(page)
        // Stop if no new messages were added (prevents infinite loop)
        guard messages.count > countBefore else { break }
      } catch {
        netLog(.error, cat: .conv, "Backfill page failed", sid: self.sessionId, data: ["error": error.localizedDescription])
        break
      }
    }
  }

  private func requiresBackfill() -> Bool {
    requiresConversationBootstrapBackfill(
      messages: messages,
      hasMoreHistoryBefore: hasMoreHistoryBefore,
      minimumTurnCount: kBootstrapMinTurns
    )
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
