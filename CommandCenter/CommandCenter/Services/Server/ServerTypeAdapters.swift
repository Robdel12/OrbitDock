//
//  ServerTypeAdapters.swift
//  OrbitDock
//
//  Converts server protocol types (ServerSessionSummary, ServerMessage, etc.)
//  to app model types (Session, TranscriptMessage) so views don't need to change.
//

import Foundation

// MARK: - ServerSessionSummary → Session

extension ServerSessionSummary {
  func toSession() -> Session {
    Session(
      id: id,
      projectPath: projectPath,
      projectName: projectName,
      model: model,
      status: status == .active ? .active : .ended,
      workStatus: workStatus.toSessionWorkStatus(),
      startedAt: parseServerTimestamp(startedAt),
      lastActivityAt: parseServerTimestamp(lastActivityAt),
      attentionReason: workStatus.toAttentionReason(hasPendingApproval: hasPendingApproval),
      provider: provider == .codex ? .codex : .claude,
      codexIntegrationMode: .direct
    )
  }
}

// MARK: - ServerSessionState → Session

extension ServerSessionState {
  func toSession() -> Session {
    var session = Session(
      id: id,
      projectPath: projectPath,
      projectName: projectName,
      model: model,
      status: status == .active ? .active : .ended,
      workStatus: workStatus.toSessionWorkStatus(),
      startedAt: parseServerTimestamp(startedAt),
      lastActivityAt: parseServerTimestamp(lastActivityAt),
      attentionReason: workStatus.toAttentionReason(hasPendingApproval: pendingApproval != nil),
      pendingToolName: pendingApproval?.toolNameForDisplay,
      pendingToolInput: pendingApproval?.toolInputForDisplay,
      pendingQuestion: pendingApproval?.question,
      provider: provider == .codex ? .codex : .claude,
      codexIntegrationMode: .direct,
      pendingApprovalId: pendingApproval?.id,
      codexInputTokens: Int(tokenUsage.inputTokens),
      codexOutputTokens: Int(tokenUsage.outputTokens),
      codexCachedTokens: Int(tokenUsage.cachedTokens),
      codexContextWindow: Int(tokenUsage.contextWindow)
    )
    session.currentDiff = currentDiff
    return session
  }
}

// MARK: - ServerWorkStatus → Session.WorkStatus

extension ServerWorkStatus {
  func toSessionWorkStatus() -> Session.WorkStatus {
    switch self {
    case .working: return .working
    case .waiting, .reply, .ended: return .waiting
    case .permission: return .permission
    case .question: return .permission // question shows as permission in the old model
    }
  }

  func toAttentionReason(hasPendingApproval: Bool = false) -> Session.AttentionReason {
    switch self {
    case .working: return .none
    case .waiting: return .awaitingReply
    case .reply: return .awaitingReply
    case .permission: return .awaitingPermission
    case .question: return .awaitingQuestion
    case .ended: return .none
    }
  }
}

// MARK: - ServerApprovalRequest helpers

extension ServerApprovalRequest {
  var toolNameForDisplay: String? {
    switch type {
    case .exec: return "Bash"
    case .patch: return "Edit"
    case .question: return nil
    }
  }

  var toolInputForDisplay: String? {
    if let cmd = command {
      return "{\"command\":\"\(cmd)\"}"
    }
    if let path = filePath {
      return "{\"file_path\":\"\(path)\"}"
    }
    return nil
  }
}

// MARK: - ServerMessage → TranscriptMessage

extension ServerMessage {
  func toTranscriptMessage() -> TranscriptMessage {
    let msgType: TranscriptMessage.MessageType = switch type {
    case .user: .user
    case .assistant: .assistant
    case .thinking: .thinking
    case .tool: .tool
    case .toolResult: .toolResult
    }

    var parsedToolInput: [String: Any]?
    if let json = toolInput, let data = json.data(using: .utf8) {
      parsedToolInput = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    let duration: TimeInterval? = durationMs.map { Double($0) / 1000.0 }

    return TranscriptMessage(
      id: id,
      type: msgType,
      content: content,
      timestamp: parseServerTimestamp(timestamp) ?? Date(),
      toolName: toolName,
      toolInput: parsedToolInput,
      toolOutput: toolOutput,
      toolDuration: duration,
      inputTokens: nil,
      outputTokens: nil,
      isInProgress: false
    )
  }
}

// MARK: - Timestamp Parsing

/// Parse server timestamps (Unix seconds or ISO 8601)
private func parseServerTimestamp(_ string: String?) -> Date? {
  guard let string, !string.isEmpty else { return nil }

  // Try Unix seconds first (what the Rust server sends: "1738800000Z")
  let stripped = string.hasSuffix("Z") ? String(string.dropLast()) : string
  if let seconds = TimeInterval(stripped) {
    return Date(timeIntervalSince1970: seconds)
  }

  // Try ISO 8601
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  if let date = formatter.date(from: string) {
    return date
  }

  // Try without fractional seconds
  formatter.formatOptions = [.withInternetDateTime]
  return formatter.date(from: string)
}
