//
//  ServerTypeAdapters.swift
//  OrbitDock
//
//  Converts server protocol types (ServerSessionSummary, ServerMessage, etc.)
//  to app model types (Session, TranscriptMessage) so views don't need to change.
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

// MARK: - ServerSessionSummary → Session

extension ServerSessionSummary {
  /// Convert to app Session model. Caller must stamp `endpointId` and `endpointName`
  /// on the returned session before inserting into `SessionStore.sessions`.
  func toSession() -> Session {
    let codexMode = RootSessionAdapterSupport.codexMode(provider: provider, mode: codexIntegrationMode)
    let claudeMode = RootSessionAdapterSupport.claudeMode(provider: provider, mode: claudeIntegrationMode)

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
      pendingToolName: pendingToolName,
      pendingToolInput: pendingToolInput,
      pendingPermissionDetail: nil,
      pendingQuestion: pendingQuestion,
      provider: RootSessionAdapterSupport.provider(from: provider),
      codexIntegrationMode: codexMode,
      claudeIntegrationMode: claudeMode,
      pendingApprovalId: pendingApprovalId,
      inputTokens: tokenUsage.map { Int($0.inputTokens) },
      outputTokens: tokenUsage.map { Int($0.outputTokens) },
      cachedTokens: tokenUsage.map { Int($0.cachedTokens) },
      contextWindow: tokenUsage.map { Int($0.contextWindow) },
      tokenUsageSnapshotKind: tokenUsageSnapshotKind ?? .unknown
    )
    session.summary = summary
    session.firstPrompt = firstPrompt
    session.lastMessage = lastMessage
    session.gitSha = gitSha
    session.currentCwd = currentCwd
    session.effort = effort
    session.collaborationMode = collaborationMode
    session.multiAgent = multiAgent
    session.personality = personality
    session.serviceTier = serviceTier
    session.developerInstructions = developerInstructions
    session.repositoryRoot = repositoryRoot
    session.isWorktree = isWorktree ?? false
    session.worktreeId = worktreeId
    session.unreadCount = unreadCount ?? 0
    if let displayTitle {
      session.displayName = displayTitle
      session.normalizedDisplayName = displayTitleSortKey ?? displayTitle.lowercased()
      session.displaySearchText = displaySearchText ?? SessionSemantics.displaySearchText(
        displayName: displayTitle,
        projectName: projectName,
        branch: gitBranch,
        model: model,
        summary: summary,
        firstPrompt: firstPrompt,
        lastMessage: lastMessage,
        projectPath: projectPath
      )
    }
    return session
  }
}

// MARK: - ServerSessionState → Session

extension ServerSessionState {
  /// Convert to app Session model. Caller must stamp `endpointId` and `endpointName`
  /// on the returned session before inserting into `SessionStore.sessions`.
  func toSession() -> Session {
    let codexMode = RootSessionAdapterSupport.codexMode(provider: provider, mode: codexIntegrationMode)
    let claudeMode = RootSessionAdapterSupport.claudeMode(provider: provider, mode: claudeIntegrationMode)

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
      attentionReason: workStatus.toAttentionReason(),
      pendingToolName: pendingToolName,
      pendingToolInput: pendingToolInput,
      pendingPermissionDetail: nil,
      pendingQuestion: pendingQuestion,
      provider: RootSessionAdapterSupport.provider(from: provider),
      codexIntegrationMode: codexMode,
      claudeIntegrationMode: claudeMode,
      pendingApprovalId: pendingApprovalId,
      inputTokens: Int(tokenUsage.inputTokens),
      outputTokens: Int(tokenUsage.outputTokens),
      cachedTokens: Int(tokenUsage.cachedTokens),
      contextWindow: Int(tokenUsage.contextWindow),
      tokenUsageSnapshotKind: tokenUsageSnapshotKind
    )
    session.summary = summary
    session.firstPrompt = firstPrompt
    session.lastMessage = lastMessage
    session.currentDiff = currentDiff
    session.gitSha = gitSha
    session.currentCwd = currentCwd
    session.effort = effort
    session.collaborationMode = collaborationMode
    session.multiAgent = multiAgent
    session.personality = personality
    session.serviceTier = serviceTier
    session.developerInstructions = developerInstructions
    session.terminalSessionId = terminalSessionId
    session.terminalApp = terminalApp
    session.repositoryRoot = repositoryRoot
    session.isWorktree = isWorktree ?? false
    session.worktreeId = worktreeId
    session.unreadCount = unreadCount ?? 0
    return session
  }
}

extension Session {
  func toRootSessionRecord() -> RootSessionRecord {
    let connectionStatus = endpointConnectionStatus ?? .disconnected

    return RootSessionRecord(
      sessionId: id,
      endpointId: endpointId,
      endpointName: endpointName,
      endpointConnectionStatus: connectionStatus,
      provider: provider,
      status: status,
      workStatus: workStatus,
      attentionReason: attentionReason,
      listStatus: RootSessionRecordSemantics.listStatus(
        status: status,
        workStatus: workStatus,
        attentionReason: attentionReason
      ),
      summary: summary,
      customName: customName,
      firstPrompt: firstPrompt,
      lastMessage: lastMessage,
      displayTitle: displayName,
      displayTitleSortKey: normalizedDisplayName,
      displaySearchText: displaySearchText,
      contextLine: RootSessionRecordSemantics.contextLine(
        summary: summary,
        firstPrompt: firstPrompt,
        lastMessage: lastMessage
      ),
      projectPath: projectPath,
      projectName: projectName,
      branch: branch,
      model: model,
      startedAt: startedAt,
      lastActivityAt: lastActivityAt,
      endedAt: endedAt,
      unreadCount: unreadCount,
      repositoryRoot: repositoryRoot,
      isWorktree: isWorktree,
      worktreeId: worktreeId,
      codexIntegrationMode: codexIntegrationMode,
      claudeIntegrationMode: claudeIntegrationMode,
      effort: effort,
      pendingToolName: pendingToolName,
      pendingQuestion: pendingQuestion,
      lastTool: lastTool,
      totalTokens: totalTokens,
      totalCostUSD: totalCostUSD,
      isActive: status == .active,
      showsInMissionControl: SessionSemantics.showsInMissionControl(
        status: status,
        endpointConnectionStatus: connectionStatus
      ),
      needsAttention: SessionSemantics.needsAttention(
        status: status,
        attentionReason: attentionReason
      ),
      isReady: SessionSemantics.isReady(
        status: status,
        attentionReason: attentionReason
      ),
      allowsUserNotifications: !(provider == .codex && codexIntegrationMode == .passive)
    )
  }
}

// MARK: - Root Session Records

extension ServerSessionListItem {
  func toSession(
    endpointId: UUID,
    endpointName: String,
    endpointConnectionStatus: ConnectionStatus
  ) -> Session {
    let appProvider = RootSessionAdapterSupport.provider(from: provider)
    let status: Session.SessionStatus = status == .active ? .active : .ended
    let workStatus = workStatus.toSessionWorkStatus()
    let codexMode = RootSessionAdapterSupport.codexMode(provider: self.provider, mode: codexIntegrationMode)
    let claudeMode = RootSessionAdapterSupport.claudeMode(provider: self.provider, mode: claudeIntegrationMode)
    let displayTitle = (displayTitle?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
      $0.isEmpty ? nil : $0
    } ?? RootSessionRecordSemantics.displayTitle(
      customName: nil,
      summary: contextLine,
      firstPrompt: nil,
      projectName: projectName,
      projectPath: projectPath
    )
    let trimmedContextLine = contextLine?.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedDisplayName = (displayTitleSortKey?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
      $0.isEmpty ? nil : $0
    } ?? RootSessionRecordSemantics.sortKey(for: displayTitle)
    let searchText = (displaySearchText?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
      $0.isEmpty ? nil : $0
    } ?? RootSessionRecordSemantics.searchText(
      displayTitle: displayTitle,
      contextLine: trimmedContextLine,
      projectName: projectName,
      branch: gitBranch,
      model: model
    )

    var session = Session(
      id: id,
      endpointId: endpointId,
      endpointName: endpointName,
      endpointConnectionStatus: endpointConnectionStatus,
      projectPath: projectPath,
      projectName: projectName,
      branch: gitBranch,
      model: model,
      summary: trimmedContextLine,
      status: status,
      workStatus: workStatus,
      startedAt: parseServerTimestamp(startedAt),
      lastActivityAt: parseServerTimestamp(lastActivityAt),
      attentionReason: attentionReason,
      provider: appProvider,
      codexIntegrationMode: codexMode,
      claudeIntegrationMode: claudeMode,
      displayName: displayTitle,
      normalizedDisplayName: normalizedDisplayName,
      displaySearchText: searchText
    )
    session.repositoryRoot = repositoryRoot
    session.isWorktree = isWorktree ?? false
    session.worktreeId = worktreeId
    session.unreadCount = unreadCount ?? 0
    session.effort = effort
    return session
  }

  func toRootSessionRecord(
    endpointId: UUID,
    endpointName: String,
    endpointConnectionStatus: ConnectionStatus
  ) -> RootSessionRecord {
    let appProvider = RootSessionAdapterSupport.provider(from: provider)
    let status: Session.SessionStatus = status == .active ? .active : .ended
    let workStatus = workStatus.toSessionWorkStatus()
    let codexMode = RootSessionAdapterSupport.codexMode(provider: self.provider, mode: codexIntegrationMode)
    let claudeMode = RootSessionAdapterSupport.claudeMode(provider: self.provider, mode: claudeIntegrationMode)
    let displayTitle = (displayTitle?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
      $0.isEmpty ? nil : $0
    } ?? RootSessionRecordSemantics.displayTitle(
      customName: nil,
      summary: contextLine,
      firstPrompt: nil,
      projectName: projectName,
      projectPath: projectPath
    )
    let contextLine = contextLine?.trimmingCharacters(in: .whitespacesAndNewlines)
    let displayTitleSortKey = (displayTitleSortKey?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
      $0.isEmpty ? nil : $0
    } ?? RootSessionRecordSemantics.sortKey(for: displayTitle)
    let displaySearchText = (displaySearchText?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
      $0.isEmpty ? nil : $0
    } ?? RootSessionRecordSemantics.searchText(
      displayTitle: displayTitle,
      contextLine: contextLine,
      projectName: projectName,
      branch: gitBranch,
      model: model
    )
    let listStatus = listStatus.map(\.toRootSessionListStatus)
      ?? RootSessionRecordSemantics.listStatus(status: status, workStatus: workStatus, attentionReason: attentionReason)
    let isActive = status == .active
    let showsInMissionControl = SessionSemantics.showsInMissionControl(
      status: status,
      endpointConnectionStatus: endpointConnectionStatus
    )
    let needsAttention = SessionSemantics.needsAttention(status: status, attentionReason: attentionReason)
    let isReady = SessionSemantics.isReady(status: status, attentionReason: attentionReason)
    let allowsUserNotifications = !(appProvider == .codex && codexMode == .passive)

    return RootSessionRecord(
      sessionId: id,
      endpointId: endpointId,
      endpointName: endpointName,
      endpointConnectionStatus: endpointConnectionStatus,
      provider: appProvider,
      status: status,
      workStatus: workStatus,
      attentionReason: attentionReason,
      listStatus: listStatus,
      summary: nil,
      customName: nil,
      firstPrompt: nil,
      lastMessage: contextLine,
      displayTitle: displayTitle,
      displayTitleSortKey: displayTitleSortKey,
      displaySearchText: displaySearchText,
      contextLine: contextLine,
      projectPath: projectPath,
      projectName: projectName,
      branch: gitBranch,
      model: model,
      startedAt: parseServerTimestamp(startedAt),
      lastActivityAt: parseServerTimestamp(lastActivityAt),
      endedAt: nil,
      unreadCount: unreadCount ?? 0,
      repositoryRoot: repositoryRoot,
      isWorktree: isWorktree ?? false,
      worktreeId: worktreeId,
      codexIntegrationMode: codexMode,
      claudeIntegrationMode: claudeMode,
      effort: effort,
      pendingToolName: nil,
      pendingQuestion: nil,
      lastTool: nil,
      totalTokens: 0,
      totalCostUSD: 0,
      isActive: isActive,
      showsInMissionControl: showsInMissionControl,
      needsAttention: needsAttention,
      isReady: isReady,
      allowsUserNotifications: allowsUserNotifications
    )
  }

  private var attentionReason: Session.AttentionReason {
    workStatus.toAttentionReason()
  }
}

extension ServerSessionSummary {
  func toRootSessionRecord(
    endpointId: UUID,
    endpointName: String,
    endpointConnectionStatus: ConnectionStatus
  ) -> RootSessionRecord {
    let appProvider = RootSessionAdapterSupport.provider(from: provider)
    let status: Session.SessionStatus = status == .active ? .active : .ended
    let workStatus = workStatus.toSessionWorkStatus()
    let codexMode = RootSessionAdapterSupport.codexMode(provider: self.provider, mode: codexIntegrationMode)
    let claudeMode = RootSessionAdapterSupport.claudeMode(provider: self.provider, mode: claudeIntegrationMode)
    let attentionReason = self.workStatus.toAttentionReason(hasPendingApproval: hasPendingApproval)
    let displayTitle = RootSessionRecordSemantics.displayTitle(
      customName: customName,
      summary: summary,
      firstPrompt: firstPrompt,
      projectName: projectName,
      projectPath: projectPath
    )
    let contextLine = RootSessionRecordSemantics.contextLine(
      summary: summary,
      firstPrompt: firstPrompt,
      lastMessage: lastMessage
    )
    let listStatus = RootSessionRecordSemantics.listStatus(
      status: status,
      workStatus: workStatus,
      attentionReason: attentionReason
    )
    let isActive = status == .active
    let showsInMissionControl = SessionSemantics.showsInMissionControl(
      status: status,
      endpointConnectionStatus: endpointConnectionStatus
    )
    let needsAttention = SessionSemantics.needsAttention(status: status, attentionReason: attentionReason)
    let isReady = SessionSemantics.isReady(status: status, attentionReason: attentionReason)
    let allowsUserNotifications = !(appProvider == .codex && codexMode == .passive)

    return RootSessionRecord(
      sessionId: id,
      endpointId: endpointId,
      endpointName: endpointName,
      endpointConnectionStatus: endpointConnectionStatus,
      provider: appProvider,
      status: status,
      workStatus: workStatus,
      attentionReason: attentionReason,
      listStatus: listStatus,
      summary: summary,
      customName: customName,
      firstPrompt: firstPrompt,
      lastMessage: lastMessage,
      displayTitle: displayTitle,
      displayTitleSortKey: RootSessionRecordSemantics.sortKey(for: displayTitle),
      displaySearchText: RootSessionRecordSemantics.searchText(
        displayTitle: displayTitle,
        contextLine: contextLine,
        projectName: projectName,
        branch: gitBranch,
        model: model
      ),
      contextLine: contextLine,
      projectPath: projectPath,
      projectName: projectName,
      branch: gitBranch,
      model: model,
      startedAt: parseServerTimestamp(startedAt),
      lastActivityAt: parseServerTimestamp(lastActivityAt),
      endedAt: nil,
      unreadCount: unreadCount ?? 0,
      repositoryRoot: repositoryRoot,
      isWorktree: isWorktree ?? false,
      worktreeId: worktreeId,
      codexIntegrationMode: codexMode,
      claudeIntegrationMode: claudeMode,
      effort: effort,
      pendingToolName: pendingToolName,
      pendingQuestion: pendingQuestion,
      lastTool: nil,
      totalTokens: 0,
      totalCostUSD: 0,
      isActive: isActive,
      showsInMissionControl: showsInMissionControl,
      needsAttention: needsAttention,
      isReady: isReady,
      allowsUserNotifications: allowsUserNotifications
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

extension ServerSessionListStatus {
  fileprivate var toRootSessionListStatus: RootSessionListStatus {
    switch self {
      case .working: .working
      case .permission: .permission
      case .question: .question
      case .reply: .reply
      case .ended: .ended
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

    let messageImages = images.enumerated().compactMap { index, image in
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
      isInProgress: isInProgress
    )
    msg.images = messageImages
    return msg
  }
}

// MARK: - Image Conversion (Lazy — no Data loaded at decode time)

private func convertServerImage(
  _ input: ServerImageInput,
  index: Int,
  endpointId: UUID?,
  sessionId: String
) -> MessageImage? {
  let imageId = "\(input.inputType):\(input.value):\(index)"
  return switch input.inputType {
    case "url":
      messageImageFromDataURI(input, imageId: imageId)
    case "path":
      messageImageFromPath(input, imageId: imageId)
    case "attachment":
      messageImageFromAttachment(
        input,
        imageId: imageId,
        endpointId: endpointId,
        sessionId: sessionId
      )
    default:
      nil
  }
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
