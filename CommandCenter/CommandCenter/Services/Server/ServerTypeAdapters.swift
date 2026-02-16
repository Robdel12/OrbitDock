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
    let codexMode: CodexIntegrationMode? = if provider == .codex {
      codexIntegrationMode?.toSessionMode() ?? .direct
    } else {
      nil
    }

    let claudeMode: ClaudeIntegrationMode? = if provider == .claude {
      claudeIntegrationMode?.toSessionMode()
    } else {
      nil
    }

    var session = Session(
      id: id,
      projectPath: projectPath,
      projectName: projectName,
      branch: gitBranch,
      model: model,
      customName: customName,
      transcriptPath: transcriptPath,
      status: status == .active ? .active : .ended,
      workStatus: workStatus.toSessionWorkStatus(),
      startedAt: parseServerTimestamp(startedAt),
      totalTokens: tokenUsage.map { Int($0.inputTokens + $0.outputTokens) } ?? 0,
      lastActivityAt: parseServerTimestamp(lastActivityAt),
      attentionReason: workStatus.toAttentionReason(hasPendingApproval: hasPendingApproval),
      provider: provider == .codex ? .codex : .claude,
      codexIntegrationMode: codexMode,
      claudeIntegrationMode: claudeMode,
      inputTokens: tokenUsage.map { Int($0.inputTokens) },
      outputTokens: tokenUsage.map { Int($0.outputTokens) },
      cachedTokens: tokenUsage.map { Int($0.cachedTokens) },
      contextWindow: tokenUsage.map { Int($0.contextWindow) }
    )
    session.summary = summary
    session.firstPrompt = firstPrompt
    session.lastMessage = lastMessage
    session.gitSha = gitSha
    session.currentCwd = currentCwd
    return session
  }
}

// MARK: - ServerSessionState → Session

extension ServerSessionState {
  func toSession() -> Session {
    let codexMode: CodexIntegrationMode? = if provider == .codex {
      codexIntegrationMode?.toSessionMode() ?? .direct
    } else {
      nil
    }

    let claudeMode: ClaudeIntegrationMode? = if provider == .claude {
      claudeIntegrationMode?.toSessionMode()
    } else {
      nil
    }

    var session = Session(
      id: id,
      projectPath: projectPath,
      projectName: projectName,
      branch: gitBranch,
      model: model,
      customName: customName,
      transcriptPath: transcriptPath,
      status: status == .active ? .active : .ended,
      workStatus: workStatus.toSessionWorkStatus(),
      startedAt: parseServerTimestamp(startedAt),
      totalTokens: Int(tokenUsage.inputTokens + tokenUsage.outputTokens),
      lastActivityAt: parseServerTimestamp(lastActivityAt),
      attentionReason: workStatus.toAttentionReason(hasPendingApproval: pendingApproval != nil),
      pendingToolName: pendingApproval?.toolNameForDisplay,
      pendingToolInput: pendingApproval?.toolInputForDisplay,
      pendingQuestion: pendingApproval?.question,
      provider: provider == .codex ? .codex : .claude,
      codexIntegrationMode: codexMode,
      claudeIntegrationMode: claudeMode,
      pendingApprovalId: pendingApproval?.id,
      inputTokens: Int(tokenUsage.inputTokens),
      outputTokens: Int(tokenUsage.outputTokens),
      cachedTokens: Int(tokenUsage.cachedTokens),
      contextWindow: Int(tokenUsage.contextWindow)
    )
    session.summary = summary
    session.firstPrompt = firstPrompt
    session.lastMessage = lastMessage
    session.currentDiff = currentDiff
    session.gitSha = gitSha
    session.currentCwd = currentCwd
    return session
  }
}

extension ServerCodexIntegrationMode {
  func toSessionMode() -> CodexIntegrationMode {
    switch self {
      case .direct: .direct
      case .passive: .passive
    }
  }
}

extension ServerClaudeIntegrationMode {
  func toSessionMode() -> ClaudeIntegrationMode {
    switch self {
      case .direct: .direct
      case .passive: .passive
    }
  }
}

// MARK: - ServerWorkStatus → Session.WorkStatus

extension ServerWorkStatus {
  func toSessionWorkStatus() -> Session.WorkStatus {
    switch self {
      case .working: .working
      case .waiting, .reply, .ended: .waiting
      case .permission: .permission
      case .question: .permission // question shows as permission in the old model
    }
  }

  func toAttentionReason(hasPendingApproval: Bool = false) -> Session.AttentionReason {
    switch self {
      case .working: .none
      case .waiting: .awaitingReply
      case .reply: .awaitingReply
      case .permission: .awaitingPermission
      case .question: .awaitingQuestion
      case .ended: .none
    }
  }
}

// MARK: - ServerApprovalRequest helpers

extension ServerApprovalRequest {
  var toolNameForDisplay: String? {
    switch type {
      case .exec: "Bash"
      case .patch: "Edit"
      case .question: nil
    }
  }

  var toolInputForDisplay: String? {
    var payload: [String: Any] = [:]
    if let cmd = command {
      payload["command"] = cmd
    }
    if let path = filePath {
      payload["file_path"] = path
    }
    guard !payload.isEmpty else { return nil }
    guard let data = try? JSONSerialization.data(withJSONObject: payload),
          let json = String(data: data, encoding: .utf8)
    else { return nil }
    return json
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
      case .steer: .steer
    }

    var parsedToolInput: [String: Any]?
    if let json = toolInput, let data = json.data(using: .utf8) {
      parsedToolInput = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    let duration: TimeInterval? = durationMs.map { Double($0) / 1_000.0 }

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
