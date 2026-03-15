//
//  ServerTypeAdapters.swift
//  OrbitDock
//
//  Detail-side protocol adaptation only.
//  Root-shell surfaces should stay on root-safe list records and never route
//  through these rich detail adapters.
//

import Foundation

private enum RootSessionAdapterSupport {
  static func provider(from provider: ServerProvider) -> Provider {
    provider == .codex ? .codex : .claude
  }

  static func codexMode(provider: ServerProvider, mode: ServerCodexIntegrationMode?) -> CodexIntegrationMode? {
    guard provider == .codex else { return nil }
    return mode?.toSessionMode() ?? .direct
  }

  static func claudeMode(provider: ServerProvider, mode: ServerClaudeIntegrationMode?) -> ClaudeIntegrationMode? {
    guard provider == .claude else { return nil }
    return mode?.toSessionMode()
  }
}

// MARK: - ServerSessionState → Detail Projection

extension ServerSessionState {
  func toDetailSnapshotProjection() -> SessionDetailSnapshotProjection {
    SessionDetailSnapshotProjection(
      endpointId: nil,
      endpointName: nil,
      projectPath: projectPath,
      projectName: projectName,
      branch: gitBranch,
      model: model,
      effort: effort,
      collaborationMode: collaborationMode,
      multiAgent: multiAgent,
      personality: personality,
      serviceTier: serviceTier,
      developerInstructions: developerInstructions,
      summary: summary,
      customName: customName,
      firstPrompt: firstPrompt,
      lastMessage: lastMessage,
      transcriptPath: transcriptPath,
      status: status == .active ? .active : .ended,
      workStatus: workStatus.toSessionWorkStatus(),
      attentionReason: workStatus.toAttentionReason(),
      lastActivityAt: parseServerTimestamp(lastActivityAt),
      lastFilesPersistedAt: nil,
      lastTool: nil,
      lastToolAt: nil,
      inputTokens: Int(tokenUsage.inputTokens),
      outputTokens: Int(tokenUsage.outputTokens),
      cachedTokens: Int(tokenUsage.cachedTokens),
      contextWindow: Int(tokenUsage.contextWindow),
      totalTokens: Int(tokenUsage.inputTokens + tokenUsage.outputTokens),
      totalCostUSD: 0,
      provider: RootSessionAdapterSupport.provider(from: provider),
      codexIntegrationMode: RootSessionAdapterSupport.codexMode(provider: provider, mode: codexIntegrationMode),
      claudeIntegrationMode: RootSessionAdapterSupport.claudeMode(provider: provider, mode: claudeIntegrationMode),
      codexThreadId: nil,
      pendingApprovalId: pendingApprovalId,
      pendingToolName: pendingToolName,
      pendingToolInput: pendingToolInput,
      pendingPermissionDetail: nil,
      pendingQuestion: pendingQuestion,
      promptCount: 0,
      toolCount: 0,
      startedAt: parseServerTimestamp(startedAt),
      endedAt: nil,
      endReason: nil,
      tokenUsageSnapshotKind: tokenUsageSnapshotKind,
      gitSha: gitSha,
      currentCwd: currentCwd,
      repositoryRoot: repositoryRoot,
      isWorktree: isWorktree ?? false,
      worktreeId: worktreeId,
      unreadCount: unreadCount ?? 0
    )
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
  nonisolated func toSessionWorkStatus() -> Session.WorkStatus {
    switch self {
      case .working: .working
      case .waiting, .reply, .ended: .waiting
      case .permission: .permission
      case .question: .permission // question shows as permission in the old model
    }
  }

  nonisolated func toAttentionReason(hasPendingApproval: Bool = false) -> Session.AttentionReason {
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
    if let name = toolName, !name.isEmpty { return name }
    return switch type {
      case .exec: "Bash"
      case .patch: "Edit"
      case .question: nil
      case .permissions: "Permissions"
    }
  }

  var toolInputForDisplay: String? {
    guard let input = toolInput, !input.isEmpty else { return nil }
    return input
  }
}

// MARK: - ServerMessage → TranscriptMessage

extension ServerMessage {
  func toConversationRowEntry(defaultSessionId: String? = nil) -> ServerConversationRowEntry {
    let resolvedSessionId = sessionId.isEmpty ? (defaultSessionId ?? "") : sessionId
    let resolvedSequence = sequence ?? 0
    let messageRow = ServerConversationMessageRow(
      id: id,
      content: content,
      turnId: nil,
      timestamp: timestamp,
      isStreaming: isInProgress,
      images: images
    )

    let row: ServerConversationRow = switch type {
      case .user:
        .user(messageRow)
      case .assistant:
        .assistant(messageRow)
      case .thinking:
        .thinking(messageRow)
      case .steer, .shell:
        .system(messageRow)
      case .tool, .toolResult:
        .tool(
          ServerConversationToolRow(
            id: id,
            provider: .codex,
            family: toolFamily.flatMap(ServerConversationToolFamily.init(rawValue:)) ?? .generic,
            kind: toolName.flatMap(ServerConversationToolKind.init(rawValue:)) ?? .generic,
            status: isInProgress ? .running : (isError ? .failed : .completed),
            title: toolName ?? content,
            subtitle: nil,
            summary: content,
            preview: nil,
            startedAt: timestamp,
            endedAt: nil,
            durationMs: durationMs,
            groupingKey: nil,
            invocation: AnyCodable(toolInputDict ?? [:]),
            result: toolOutput.map { AnyCodable(["output": $0]) },
            renderHints: ServerConversationRenderHints(),
            toolDisplay: toolDisplay
          )
        )
    }

    return ServerConversationRowEntry(
      sessionId: resolvedSessionId,
      sequence: resolvedSequence,
      turnId: nil,
      row: row
    )
  }

  func toTranscriptMessage(endpointId: UUID? = nil) -> TranscriptMessage {
    let msgType: TranscriptMessage.MessageType = switch type {
      case .user: .user
      case .assistant: .assistant
      case .thinking: .thinking
      case .tool: .tool
      case .toolResult: .toolResult
      case .steer: .steer
      case .shell: .shell
    }

    var parsedToolInput: [String: Any]?
    if let json = toolInput, let data = json.data(using: .utf8) {
      parsedToolInput = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    let duration: TimeInterval? = durationMs.map { Double($0) / 1_000.0 }

    let messageImages = (images ?? []).enumerated().compactMap { index, image in
      convertServerImage(
        image,
        index: index,
        endpointId: endpointId,
        sessionId: sessionId
      )
    }

    var msg = TranscriptMessage(
      id: id,
      sequence: sequence,
      type: msgType,
      content: content,
      timestamp: parseServerTimestamp(timestamp) ?? Date(),
      toolName: toolName,
      toolInput: parsedToolInput,
      rawToolInput: toolInput,
      toolOutput: toolOutput,
      toolDuration: duration,
      inputTokens: nil,
      outputTokens: nil,
      isError: isError,
      isInProgress: isInProgress,
      serverToolFamily: toolFamily,
      toolDisplay: toolDisplay
    )
    msg.images = messageImages
    return msg
  }
}

extension ServerConversationRowEntry {
  func toTranscriptMessage(endpointId: UUID? = nil) -> TranscriptMessage {
    switch row {
      case .user(let message):
        return message.toTranscriptMessage(
          type: .user,
          sessionId: sessionId,
          sequence: sequence,
          turnId: turnId,
          endpointId: endpointId
        )
      case .assistant(let message):
        return message.toTranscriptMessage(
          type: .assistant,
          sessionId: sessionId,
          sequence: sequence,
          turnId: turnId,
          endpointId: endpointId
        )
      case .thinking(let message):
        return message.toTranscriptMessage(
          type: .thinking,
          sessionId: sessionId,
          sequence: sequence,
          turnId: turnId,
          endpointId: endpointId
        )
      case .system(let message):
        return message.toTranscriptMessage(
          type: .system,
          sessionId: sessionId,
          sequence: sequence,
          turnId: turnId,
          endpointId: endpointId
        )
      case .tool(let tool):
        return tool.toTranscriptMessage(sequence: sequence, timestamp: parseServerTimestamp(tool.startedAt) ?? Date())
      case .activityGroup(let group):
        return group.toTranscriptMessage(sequence: sequence)
      case .approval(let approval):
        return approval.toTranscriptMessage(sequence: sequence)
      case .question(let question):
        return question.toTranscriptMessage(sequence: sequence)
      case .worker(let worker):
        return worker.toTranscriptMessage(sequence: sequence)
      case .plan(let plan):
        return plan.toTranscriptMessage(sequence: sequence)
      case .hook(let hook):
        return hook.toTranscriptMessage(sequence: sequence)
      case .handoff(let handoff):
        return handoff.toTranscriptMessage(sequence: sequence)
    }
  }
}

private extension ServerConversationMessageRow {
  func toTranscriptMessage(
    type: TranscriptMessage.MessageType,
    sessionId: String,
    sequence: UInt64,
    turnId: String?,
    endpointId: UUID?
  ) -> TranscriptMessage {
    let messageImages = (images ?? []).enumerated().compactMap { index, image in
      convertServerImage(image, index: index, endpointId: endpointId, sessionId: sessionId)
    }
    var message = TranscriptMessage(
      id: id,
      sequence: sequence,
      type: type,
      content: content,
      timestamp: parseServerTimestamp(timestamp) ?? Date(),
      isInProgress: isStreaming,
      images: messageImages
    )
    if type == .thinking {
      message.thinking = content
    }
    return message
  }
}

private extension ServerConversationToolRow {
  func toTranscriptMessage(sequence: UInt64, timestamp: Date) -> TranscriptMessage {
    let toolInput = anyJSONObject(from: invocation.value)
    let rawToolInput = prettyJSONString(from: invocation.value)
    let rawToolOutput = result.flatMap { prettyJSONString(from: $0.value) }
    return TranscriptMessage(
      id: id,
      sequence: sequence,
      type: .tool,
      content: summary ?? subtitle ?? title,
      timestamp: timestamp,
      toolName: kind.rawValue,
      toolInput: toolInput,
      rawToolInput: rawToolInput,
      toolOutput: rawToolOutput,
      toolDuration: durationMs.map { Double($0) / 1_000.0 },
      isError: status == .failed,
      isInProgress: status == .running || status == .pending || status == .needsInput,
      serverToolFamily: family.rawValue,
      toolDisplay: toolDisplay
    )
  }
}

private extension ServerConversationActivityGroupRow {
  func toTranscriptMessage(sequence: UInt64) -> TranscriptMessage {
    let childPayloads = children.map { child in
      [
        "id": child.id,
        "title": child.title,
        "kind": child.kind.rawValue,
        "status": child.status.rawValue,
      ]
    }
    return TranscriptMessage(
      id: id,
      sequence: sequence,
      type: .tool,
      content: summary ?? title,
      timestamp: Date(),
      toolName: "activity_group",
      toolInput: [
        "group_kind": groupKind.rawValue,
        "child_count": childCount,
        "children": childPayloads,
      ],
      rawToolInput: prettyJSONString(from: [
        "group_kind": groupKind.rawValue,
        "child_count": childCount,
        "children": childPayloads,
      ]),
      toolDuration: nil,
      isError: status == .failed,
      isInProgress: status == .running,
      serverToolFamily: family?.rawValue ?? "generic"
    )
  }
}

private extension ServerConversationApprovalRow {
  func toTranscriptMessage(sequence: UInt64) -> TranscriptMessage {
    TranscriptMessage(
      id: id,
      sequence: sequence,
      type: .system,
      content: summary ?? title,
      timestamp: Date(),
      toolName: "approval",
      rawToolInput: prettyJSONString(from: request.value),
      isInProgress: true,
      serverToolFamily: "approval"
    )
  }
}

private extension ServerConversationQuestionRow {
  func toTranscriptMessage(sequence: UInt64) -> TranscriptMessage {
    TranscriptMessage(
      id: id,
      sequence: sequence,
      type: .system,
      content: summary ?? title,
      timestamp: Date(),
      toolName: "question",
      rawToolInput: prettyJSONString(from: [
        "prompts": prompts.map { ["id": $0.id, "question": $0.question] },
      ]),
      isInProgress: response == nil,
      serverToolFamily: "question"
    )
  }
}

private extension ServerConversationWorkerRow {
  func toTranscriptMessage(sequence: UInt64) -> TranscriptMessage {
    TranscriptMessage(
      id: id,
      sequence: sequence,
      type: .tool,
      content: summary ?? title,
      timestamp: Date(),
      toolName: "task",
      rawToolInput: prettyJSONString(from: worker.value),
      serverToolFamily: "agent"
    )
  }
}

private extension ServerConversationPlanRow {
  func toTranscriptMessage(sequence: UInt64) -> TranscriptMessage {
    TranscriptMessage(
      id: id,
      sequence: sequence,
      type: .system,
      content: summary ?? title,
      timestamp: Date(),
      toolName: "plan",
      rawToolInput: prettyJSONString(from: payload.value),
      serverToolFamily: "plan"
    )
  }
}

private extension ServerConversationHookRow {
  func toTranscriptMessage(sequence: UInt64) -> TranscriptMessage {
    TranscriptMessage(
      id: id,
      sequence: sequence,
      type: .tool,
      content: summary ?? title,
      timestamp: Date(),
      toolName: "hook",
      rawToolInput: prettyJSONString(from: payload.value),
      serverToolFamily: "hook"
    )
  }
}

private extension ServerConversationHandoffRow {
  func toTranscriptMessage(sequence: UInt64) -> TranscriptMessage {
    TranscriptMessage(
      id: id,
      sequence: sequence,
      type: .tool,
      content: summary ?? title,
      timestamp: Date(),
      toolName: "handoff",
      rawToolInput: prettyJSONString(from: payload.value),
      serverToolFamily: "handoff"
    )
  }
}

private func anyJSONObject(from value: Any) -> [String: Any]? {
  value as? [String: Any]
}

private func prettyJSONString(from value: Any) -> String? {
  guard JSONSerialization.isValidJSONObject(value),
        let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]),
        let text = String(data: data, encoding: .utf8)
  else {
    return nil
  }
  return text
}

// MARK: - Image Conversion (Lazy — no Data loaded at decode time)

extension ServerImageInput {
  func toMessageImage(index: Int, endpointId: UUID? = nil, sessionId: String) -> MessageImage? {
    let imageId = "\(inputType):\(value):\(index)"
    return switch inputType {
    case "url":
      messageImageFromDataURI(self, imageId: imageId)
    case "path":
      messageImageFromPath(self, imageId: imageId)
    case "attachment":
      messageImageFromAttachment(
        self,
        imageId: imageId,
        endpointId: endpointId,
        sessionId: sessionId
      )
    default:
      nil
    }
  }
}

private func convertServerImage(
  _ input: ServerImageInput,
  index: Int,
  endpointId: UUID?,
  sessionId: String
) -> MessageImage? {
  input.toMessageImage(index: index, endpointId: endpointId, sessionId: sessionId)
}

private func messageImageFromPath(_ input: ServerImageInput, imageId: String) -> MessageImage? {
  let path = input.value
  let url = URL(fileURLWithPath: path)
  let byteCount = input.byteCount
    ?? ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0)
  let mimeType = input.mimeType ?? mimeTypeForExtension(url.pathExtension)
  return MessageImage(
    id: imageId,
    source: .filePath(path),
    mimeType: mimeType,
    byteCount: byteCount,
    pixelWidth: input.pixelWidth,
    pixelHeight: input.pixelHeight
  )
}

private func messageImageFromDataURI(_ input: ServerImageInput, imageId: String) -> MessageImage? {
  let uri = input.value
  guard uri.hasPrefix("data:") else { return nil }
  let withoutScheme = String(uri.dropFirst(5))
  guard let commaIndex = withoutScheme.firstIndex(of: ",") else { return nil }
  let meta = String(withoutScheme[withoutScheme.startIndex ..< commaIndex])
  guard meta.hasSuffix(";base64") else { return nil }
  let mimeType = String(meta.dropLast(7))
  // Estimate decoded size from base64 length (3 bytes per 4 chars)
  let base64Len = withoutScheme.distance(from: withoutScheme.index(after: commaIndex), to: withoutScheme.endIndex)
  let byteCount = input.byteCount ?? (base64Len * 3 / 4)
  return MessageImage(
    id: imageId,
    source: .dataURI(uri),
    mimeType: input.mimeType ?? (mimeType.isEmpty ? "image/png" : mimeType),
    byteCount: byteCount,
    pixelWidth: input.pixelWidth,
    pixelHeight: input.pixelHeight
  )
}

private func messageImageFromAttachment(
  _ input: ServerImageInput,
  imageId: String,
  endpointId: UUID?,
  sessionId: String
) -> MessageImage? {
  let mimeType = input.mimeType ?? mimeTypeForExtension(URL(fileURLWithPath: input.value).pathExtension)
  return MessageImage(
    id: imageId,
    source: .serverAttachment(
      ServerAttachmentImageReference(
        endpointId: endpointId,
        sessionId: sessionId,
        attachmentId: input.value
      )
    ),
    mimeType: mimeType,
    byteCount: input.byteCount ?? 0,
    pixelWidth: input.pixelWidth,
    pixelHeight: input.pixelHeight
  )
}

private func mimeTypeForExtension(_ ext: String) -> String {
  switch ext.lowercased() {
    case "png": "image/png"
    case "jpg", "jpeg": "image/jpeg"
    case "gif": "image/gif"
    case "webp": "image/webp"
    case "svg": "image/svg+xml"
    case "bmp": "image/bmp"
    case "tiff", "tif": "image/tiff"
    default: "image/png"
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
