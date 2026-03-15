//
//  ConversationStore.swift
//  OrbitDock
//
//  Per-session conversation state: messages, pagination, and live updates.
//  Owns all conversation data loading via typed server clients (HTTP).
//  Receives live updates from EventStream events (pushed by SessionStore).
//

import Foundation

private let kPageSize = 50

/// Compatibility shim for views that check hydration state
enum ConversationHydrationState: Sendable, Equatable {
  case empty
  case loadingRecent
  case readyPartial
  case readyComplete
  case failed

  var hasRenderableConversation: Bool {
    switch self {
    case .readyPartial, .readyComplete: true
    default: false
    }
  }
}


// MARK: - ConversationStore

@Observable
@MainActor
final class ConversationStore {
  enum State {
    case idle
    case loading
    case ready
    case failed
  }

  let sessionId: String
  let endpointId: UUID
  private let clients: ServerClients

  // MARK: - Observable state

  private(set) var messages: [TranscriptMessage] = []
  private(set) var rowEntries: [ServerConversationRowEntry] = []
  private(set) var totalMessageCount: Int = 0
  private(set) var hasMoreHistoryBefore: Bool = false
  private(set) var isLoadingOlderMessages: Bool = false
  private(set) var state: State = .idle
  private(set) var messagesRevision: Int = 0
  private(set) var rowEntriesRevision: Int = 0
  private(set) var streamingPatchRevision: Int = 0
  var latestStreamingPatch: ConversationStreamingPatch?

  @ObservationIgnored private(set) var oldestLoadedSequence: UInt64?
  @ObservationIgnored private(set) var newestLoadedSequence: UInt64?

  /// Convenience for views — returns messages directly (old code had normalization layer)
  var normalizedMessages: [TranscriptMessage] { messages }

  /// Whether there's enough data to render
  var hasRenderableConversation: Bool { !messages.isEmpty }

  /// Whether initial data has been loaded
  var hasReceivedInitialData: Bool { state == .ready }

  /// Compatibility with old hydration state
  var hydrationState: ConversationHydrationState {
    switch state {
    case .idle: .empty
    case .loading: .loadingRecent
    case .ready: messages.count < totalMessageCount ? .readyPartial : .readyComplete
    case .failed: .failed
    }
  }

  var serverClients: ServerClients {
    clients
  }

  init(sessionId: String, endpointId: UUID, clients: ServerClients) {
    self.sessionId = sessionId
    self.endpointId = endpointId
    self.clients = clients
  }

  // MARK: - Bootstrap (initial load from HTTP)

  /// Fetch the bootstrap payload from the server without applying it.
  /// Use this when the caller will handle applying via a separate path
  /// (e.g. `SessionStore.handleConversationBootstrap`).
  func fetchBootstrap() async -> ServerConversationBootstrap? {
    netLog(.info, cat: .conv, "Fetching bootstrap", sid: self.sessionId)
    if state != .ready {
      state = .loading
    }
    do {
      let result = try await clients.conversation.fetchConversationBootstrap(sessionId, limit: kPageSize)
      netLog(.info, cat: .conv, "Bootstrap fetched", sid: self.sessionId, data: ["rows": result.rows.count])
      return result
    } catch {
      state = messages.isEmpty ? .failed : .ready
      netLog(.error, cat: .conv, "Bootstrap fetch failed", sid: self.sessionId, data: ["error": error.localizedDescription])
      return nil
    }
  }

  /// Fetch and apply the bootstrap in one step. Used by `bootstrapFresh()`
  /// where there is no separate session-level apply path.
  func bootstrap() async -> ServerConversationBootstrap? {
    let result = await fetchBootstrap()
    if let result { applyBootstrap(result) }
    return result
  }

  /// Cancel any in-flight work and re-bootstrap, awaitable by the caller.
  func bootstrapFresh() async {
    netLog(.warning, cat: .conv, "Fresh bootstrap requested", sid: self.sessionId)
    _ = await bootstrap()
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

  func handleConversationBootstrap(
    upserted: [ServerConversationRowEntry],
    removedRowIds: [String],
    totalRowCount: UInt64,
    hasMoreBefore: Bool,
    oldestSequence: UInt64?,
    newestSequence: UInt64?
  ) {
    applyRowsUpdate(
      upserted: upserted,
      removedRowIds: removedRowIds,
      totalRowCount: totalRowCount,
      hasMoreBefore: hasMoreBefore,
      oldestSequence: oldestSequence,
      newestSequence: newestSequence
    )
  }

  func handleConversationRowsChanged(
    upserted: [ServerConversationRowEntry],
    removedRowIds: [String],
    totalRowCount: UInt64?
  ) {
    guard !upserted.isEmpty || !removedRowIds.isEmpty || totalRowCount != nil else { return }

    // Maintain raw row entries for the new timeline
    applyRowEntries(upserted: upserted, removedRowIds: removedRowIds)

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
    totalMessageCount = totalRowCount.map(Int.init) ?? max(totalMessageCount, messages.count)
    oldestLoadedSequence = messages.compactMap(\.sequence).min()
    newestLoadedSequence = messages.compactMap(\.sequence).max()
    state = .ready
  }

  /// Clear all message data (e.g. on unsubscribe).
  func clear() {
    messages = []
    rowEntries = []
    totalMessageCount = 0
    oldestLoadedSequence = nil
    newestLoadedSequence = nil
    hasMoreHistoryBefore = false
    state = .idle
    netLog(.info, cat: .conv, "Cleared conversation", sid: self.sessionId)
  }

  // MARK: - Private

  private func applyBootstrap(_ bootstrap: ServerConversationBootstrap) {
    applyRowsUpdate(
      upserted: bootstrap.rows,
      removedRowIds: [],
      totalRowCount: bootstrap.totalRowCount,
      hasMoreBefore: bootstrap.hasMoreBefore,
      oldestSequence: bootstrap.oldestSequence,
      newestSequence: bootstrap.newestSequence
    )
  }

  private func applyHistoryPage(_ page: ServerConversationHistoryPage) {
    let beforeCount = messages.count
    applyRowsUpdate(
      upserted: page.rows,
      removedRowIds: [],
      totalRowCount: page.totalRowCount,
      hasMoreBefore: page.hasMoreBefore,
      oldestSequence: page.oldestSequence,
      newestSequence: page.newestSequence
    )
    netLog(.debug, cat: .conv, "Applied history page", sid: self.sessionId, data: ["added": messages.count - beforeCount, "total": self.messages.count])
  }

  private func applyRowsUpdate(
    upserted: [ServerConversationRowEntry],
    removedRowIds: [String],
    totalRowCount: UInt64,
    hasMoreBefore: Bool,
    oldestSequence: UInt64?,
    newestSequence: UInt64?
  ) {
    // Maintain raw row entries for the new timeline
    applyRowEntries(upserted: upserted, removedRowIds: removedRowIds)

    let incoming = normalizeMessages(upserted.map { $0.toTranscriptMessage(endpointId: endpointId) })

    var merged = messages
    let existingIDs = Dictionary(uniqueKeysWithValues: merged.enumerated().map { ($1.id, $0) })

    for msg in incoming {
      if let existingIdx = existingIDs[msg.id] {
        merged[existingIdx] = mergeMessage(merged[existingIdx], with: msg)
      } else {
        merged.append(msg)
      }
    }

    if !removedRowIds.isEmpty {
      let removed = Set(removedRowIds)
      merged.removeAll { removed.contains($0.id) }
    }

    merged.sort { lhs, rhs in
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
    messagesRevision += 1
    totalMessageCount = max(Int(totalRowCount), messages.count)
    self.oldestLoadedSequence = min(self.oldestLoadedSequence ?? UInt64.max, oldestSequence ?? messages.compactMap(\.sequence).min() ?? UInt64.max)
    if self.oldestLoadedSequence == UInt64.max {
      self.oldestLoadedSequence = nil
    }
    self.newestLoadedSequence = max(self.newestLoadedSequence ?? 0, newestSequence ?? messages.compactMap(\.sequence).max() ?? 0)
    if self.newestLoadedSequence == 0 {
      self.newestLoadedSequence = nil
    }
    self.hasMoreHistoryBefore = hasMoreBefore
    state = .ready
  }

  // MARK: - Row Entries

  private func applyRowEntries(upserted: [ServerConversationRowEntry], removedRowIds: [String]) {
    guard !upserted.isEmpty || !removedRowIds.isEmpty else { return }

    var merged = rowEntries
    let existingIDs = Dictionary(merged.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { _, last in last })

    for entry in upserted {
      if let existingIdx = existingIDs[entry.id] {
        merged[existingIdx] = entry
      } else {
        merged.append(entry)
      }
    }

    if !removedRowIds.isEmpty {
      let removed = Set(removedRowIds)
      merged.removeAll { removed.contains($0.id) }
    }

    merged.sort { lhs, rhs in
      lhs.sequence < rhs.sequence
    }

    rowEntries = merged
    rowEntriesRevision += 1
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
      thinking: msg.thinking,
      serverToolFamily: msg.serverToolFamily,
      toolDisplay: msg.toolDisplay
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
      images: incoming.images,
      thinking: incoming.thinking ?? existing.thinking,
      serverToolFamily: incoming.serverToolFamily ?? existing.serverToolFamily,
      toolDisplay: incoming.toolDisplay ?? existing.toolDisplay
    )
  }
}
