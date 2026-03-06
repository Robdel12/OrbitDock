//
//  ConversationRenderMessageNormalizer.swift
//  OrbitDock
//
//  Deduplicates transcript messages before they enter the render pipeline.
//

import Foundation
import OSLog

enum ConversationRenderMessageNormalizer {
  private static let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "OrbitDock",
    category: "conversation-message-normalizer"
  )

  static func normalize(
    _ incoming: [TranscriptMessage],
    sessionId: String?,
    source: String
  ) -> [TranscriptMessage] {
    guard !incoming.isEmpty else { return [] }

    let resolvedSessionID = normalizedSessionID(sessionId)
    var normalized: [TranscriptMessage] = []
    normalized.reserveCapacity(incoming.count)
    var indexByID: [String: Int] = [:]
    var syntheticCount = 0
    var duplicateCount = 0

    for (index, raw) in incoming.enumerated() {
      let resolvedID = normalizedMessageID(
        for: raw,
        sessionId: resolvedSessionID,
        source: source,
        index: index
      )
      if resolvedID != raw.id {
        syntheticCount += 1
      }

      let message = resolvedID == raw.id ? raw : withMessageID(raw, id: resolvedID)
      if let existingIndex = indexByID[resolvedID] {
        normalized[existingIndex] = merge(normalized[existingIndex], with: message)
        duplicateCount += 1
      } else {
        indexByID[resolvedID] = normalized.count
        normalized.append(message)
      }
    }

    if syntheticCount > 0 || duplicateCount > 0 {
      logger.warning(
        "Normalized render messages for \(resolvedSessionID, privacy: .public) source=\(source, privacy: .public) in=\(incoming.count, privacy: .public) out=\(normalized.count, privacy: .public) synthetic=\(syntheticCount, privacy: .public) duplicates=\(duplicateCount, privacy: .public)"
      )
    }

    return normalized
  }

  static func merge(_ existing: TranscriptMessage, with incoming: TranscriptMessage) -> TranscriptMessage {
    let mergedThinking: String? = {
      if let incomingThinking = incoming.thinking,
         !incomingThinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        return incomingThinking
      }
      return existing.thinking
    }()

    return TranscriptMessage(
      id: incoming.id,
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
      isError: incoming.isError || existing.isError,
      isInProgress: incoming.isInProgress,
      images: incoming.images.isEmpty ? existing.images : incoming.images,
      thinking: mergedThinking
    )
  }

  private static func normalizedSessionID(_ sessionId: String?) -> String {
    let trimmed = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? "unknown-session" : trimmed
  }

  private static func normalizedMessageID(
    for message: TranscriptMessage,
    sessionId: String,
    source: String,
    index: Int
  ) -> String {
    let trimmed = message.id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty else { return trimmed }

    let millis = Int(message.timestamp.timeIntervalSince1970 * 1_000)
    let tool = message.toolName ?? "-"
    let contentPrefix = String(message.content.prefix(32))
    return "render:\(sessionId):\(source):\(message.type.rawValue):\(millis):\(index):\(tool):\(contentPrefix.count):\(contentPrefix)"
  }

  private static func withMessageID(_ message: TranscriptMessage, id: String) -> TranscriptMessage {
    TranscriptMessage(
      id: id,
      type: message.type,
      content: message.content,
      timestamp: message.timestamp,
      toolName: message.toolName,
      toolInput: message.toolInput,
      rawToolInput: message.rawToolInput,
      toolOutput: message.toolOutput,
      toolDuration: message.toolDuration,
      inputTokens: message.inputTokens,
      outputTokens: message.outputTokens,
      isError: message.isError,
      isInProgress: message.isInProgress,
      images: message.images,
      thinking: message.thinking
    )
  }
}
