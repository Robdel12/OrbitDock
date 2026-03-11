//
//  ConversationTimelineProjector.swift
//  OrbitDock
//
//  Pure projector that produces deterministic flat timeline rows + structural diff.
//

import Foundation

private struct FocusedTurnSplit {
  let leading: [TranscriptMessage]
  let toolZone: [TranscriptMessage]
  let trailing: [TranscriptMessage]
  let toolCount: Int
}

private enum ToolZoneSegment {
  case breaker(TranscriptMessage)
  case workGroup([TranscriptMessage])
}

nonisolated enum ConversationTimelineProjector {
  private static let focusedCollapseThreshold = 2
  private static let focusedVisibleToolTail = 2

  static func project(
    source: ConversationSourceState,
    ui: ConversationUIState,
    previous: ProjectionResult = .empty
  ) -> ProjectionResult {
    let context = ProjectionContext(source: source, ui: ui)
    let rows = buildRows(context: context)
    let (diff, dirtyRowIDs) = buildDiff(previousRows: previous.rows, nextRows: rows)
    return ProjectionResult(rows: rows, diff: diff, dirtyRowIDs: dirtyRowIDs)
  }

  private static func buildRows(context: ProjectionContext) -> [TimelineRow] {
    let metadata = context.source.metadata
    var rows: [TimelineRow] = []
    rows.reserveCapacity(context.source.messages.count + context.source.turns.count * 2 + 6)

    if metadata.hasMoreMessages {
      rows.append(makeRow(id: .loadMore, kind: .loadMore, payload: .none, context: context))
    }

    if metadata.messageCount > 50 {
      rows.append(makeRow(id: .messageCount, kind: .messageCount, payload: .none, context: context))
    }

    switch metadata.chatViewMode {
      case .verbose:
        for message in context.source.messages {
          appendMessageRow(message, toolRowsEnabled: true, context: context, rows: &rows)
        }

      case .focused:
        for turn in context.source.turns {
          appendFocusedRows(for: turn, context: context, rows: &rows)
        }
    }

    // Approval card takes priority over live indicator — it replaces the
    // "waiting" indicator when the session is blocked on an approval/question.
    if metadata.needsApprovalCard, metadata.approvalMode != .none {
      rows.append(makeRow(
        id: .approvalCard,
        kind: .approvalCard,
        payload: .approvalCard(mode: metadata.approvalMode),
        context: context
      ))
    } else if metadata.shouldShowLiveIndicator {
      rows.append(makeRow(id: .liveIndicator, kind: .liveIndicator, payload: .none, context: context))
    } else if metadata.isSessionActive, metadata.workStatus == .working {
      let lastTurn = context.source.turns.last
      let toolCount = lastTurn?.messages.filter(isToolLikeMessage).count ?? 0
      let elapsed = lastTurn?.messages.compactMap(\.toolDuration).reduce(0, +) ?? 0
      let currentTool = metadata.currentTool ?? ""
      rows.append(makeRow(
        id: .liveProgress,
        kind: .liveProgress,
        payload: .liveProgress(
          currentTool: currentTool,
          completedCount: toolCount,
          elapsedTime: elapsed
        ),
        context: context
      ))
    }

    rows.append(makeRow(id: .bottomSpacer, kind: .bottomSpacer, payload: .none, context: context))
    return rows
  }

  private static func appendFocusedRows(
    for turn: TurnSummary,
    context: ProjectionContext,
    rows: inout [TimelineRow]
  ) {
    rows.append(
      makeRow(
        id: .turnHeader(turn.id),
        kind: .turnHeader,
        payload: .turnHeader(turnID: turn.id, turnNumber: turn.turnNumber, timestamp: turn.startTimestamp),
        context: context
      )
    )

    if let workerRow = workerOrchestrationRow(for: turn, context: context) {
      rows.append(workerRow)
    }

    let split = splitFocusedTurnMessages(turn.messages)

    for message in split.leading {
      appendMessageRow(message, toolRowsEnabled: true, context: context, rows: &rows)
    }

    if split.toolZone.isEmpty {
      for message in split.trailing {
        appendMessageRow(message, toolRowsEnabled: true, context: context, rows: &rows)
      }
      return
    }

    let segments = segmentToolZone(split.toolZone)
    for (index, segment) in segments.enumerated() {
      switch segment {
        case let .breaker(message):
          appendMessageRow(message, toolRowsEnabled: true, context: context, rows: &rows)

        case let .workGroup(groupMessages):
          appendFocusedWorkGroup(
            groupMessages,
            turnID: turn.id,
            segmentIndex: index,
            context: context,
            rows: &rows
          )
      }
    }

    for message in split.trailing {
      appendMessageRow(message, toolRowsEnabled: true, context: context, rows: &rows)
    }
  }

  private static func workerOrchestrationRow(
    for turn: TurnSummary,
    context: ProjectionContext
  ) -> TimelineRow? {
    let workerIDs = turn.messages.reduce(into: [String]()) { result, message in
      guard let workerID = SharedModelBuilders.linkedWorkerID(for: message) else { return }
      guard !result.contains(workerID) else { return }
      result.append(workerID)
    }

    guard !workerIDs.isEmpty else { return nil }

    return makeRow(
      id: .workerOrchestration(turn.id),
      kind: .workerOrchestration,
      payload: .workerOrchestration(turnID: turn.id, workerIDs: workerIDs),
      context: context
    )
  }

  private static func appendFocusedWorkGroup(
    _ messages: [TranscriptMessage],
    turnID: String,
    segmentIndex: Int,
    context: ProjectionContext,
    rows: inout [TimelineRow]
  ) {
    guard !messages.isEmpty else { return }

    let toolMessages = messages.filter(isToolLikeMessage)
    let totalToolCount = toolMessages.count

    guard totalToolCount > focusedCollapseThreshold else {
      for message in messages {
        appendMessageRow(message, toolRowsEnabled: true, context: context, rows: &rows)
      }
      return
    }

    let rollupID = "\(TimelineRowID.turnRollupKey(turnID)):\(segmentIndex)"
    let isExpanded = context.ui.expandedRollups.contains(rollupID)
    let visibleTailCount = min(focusedVisibleToolTail, messages.count)
    let hiddenCount = max(0, messages.count - visibleTailCount)
    let hiddenMessages = Array(messages.prefix(hiddenCount))
    let hiddenMessageIDs = hiddenMessages.map(\.id)

    rows.append(
      makeRow(
        id: .rollupSummary(rollupID),
        kind: .rollupSummary,
        payload: .rollupSummary(
          id: rollupID,
          hiddenCount: hiddenMessages.count,
          totalToolCount: totalToolCount,
          isExpanded: isExpanded,
          breakdown: toolBreakdown(from: hiddenMessages),
          hiddenMessageIDs: hiddenMessageIDs
        ),
        context: context
      )
    )

    if isExpanded {
      for message in hiddenMessages {
        appendMessageRow(message, toolRowsEnabled: true, context: context, rows: &rows)
      }
    }

    for message in messages.suffix(visibleTailCount) {
      appendMessageRow(message, toolRowsEnabled: true, context: context, rows: &rows)
    }
  }

  private static func appendCollapsedTurn(
    _ turn: TurnSummary,
    context: ProjectionContext,
    rows: inout [TimelineRow]
  ) {
    let userPreview = turn.messages
      .first { $0.type == .user }
      .map { String($0.content.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines) }
      ?? ""

    let assistantPreview = turn.messages
      .first { $0.type == .assistant && !$0.content.isEmpty }
      .map { String($0.content.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines) }
      ?? ""

    let toolCount = turn.messages.filter(isToolLikeMessage).count
    let totalDuration = turn.messages.compactMap(\.toolDuration).reduce(0, +)

    rows.append(
      makeRow(
        id: .collapsedTurn(turn.id),
        kind: .collapsedTurn,
        payload: .collapsedTurn(
          turnID: turn.id,
          userPreview: userPreview,
          assistantPreview: assistantPreview,
          toolCount: toolCount,
          totalDuration: totalDuration > 0 ? totalDuration : nil
        ),
        context: context
      )
    )
  }

  private static func appendMessageRow(
    _ message: TranscriptMessage,
    toolRowsEnabled: Bool,
    context: ProjectionContext,
    rows: inout [TimelineRow]
  ) {
    // Hide system noise — local-command-caveat is instructions for Claude, not the user
    if message.type == .user, message.content.contains("<local-command-caveat>") {
      return
    }
    if shouldHideRedundantApprovalPrompt(message, metadata: context.source.metadata) {
      return
    }

    let isWorkerRow = toolRowsEnabled && isWorkerLinkedToolMessage(message)
    let isToolRow = toolRowsEnabled && isToolLikeMessage(message) && !isWorkerRow
    let showHeader = isToolRow ? true : shouldShowHeader(for: message, previousRow: rows.last, context: context)
    rows.append(
      makeRow(
        id: isWorkerRow ? .workerEvent(message.id) : (isToolRow ? .tool(message.id) : .message(message.id)),
        kind: isWorkerRow ? .workerEvent : (isToolRow ? .tool : .message),
        payload: isWorkerRow
          ? .workerEvent(id: message.id)
          : (isToolRow ? .tool(id: message.id) : .message(id: message.id, showHeader: showHeader)),
        context: context
      )
    )
  }

  private static func shouldShowHeader(
    for message: TranscriptMessage,
    previousRow: TimelineRow?,
    context: ProjectionContext
  ) -> Bool {
    if message.type == .user || message.type == .shell { return true }
    if message.isError, message.type == .assistant { return true }
    if message.type == .steer { return true }

    guard let previousRow,
          case let .message(prevID, _) = previousRow.payload,
          let previousMessage = context.messagesByID[prevID]
    else {
      return true
    }

    return messageRole(message) != messageRole(previousMessage)
  }

  private static func messageRole(_ message: TranscriptMessage) -> String {
    switch message.type {
      case .user, .shell:
        "user"
      case .thinking:
        "thinking"
      case .steer:
        "steer"
      case .assistant where message.isError:
        "error"
      default:
        "assistant"
    }
  }

  private static func shouldHideRedundantApprovalPrompt(
    _ message: TranscriptMessage,
    metadata: ConversationSourceState.SessionMetadata
  ) -> Bool {
    guard metadata.needsApprovalCard, metadata.approvalMode == .permission else { return false }
    guard let pendingCommand = pendingApprovalCommand(from: metadata) else { return false }

    if isToolLikeMessage(message) {
      guard ((message.toolName?.lowercased() ?? "") == "bash") || message.type == .shell else { return false }
      let hasOutput = !(message.toolOutput?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
      guard !hasOutput else { return false }
      let messageCommand = commandFromToolMessage(message)
      return commandsLikelyMatch(messageCommand, pendingCommand)
    }

    if message.type == .assistant {
      let lower = message.content.lowercased()
      guard lower.contains("requesting escalated command execution") else { return false }
      return commandMentioned(message.content, pendingCommand: pendingCommand)
    }

    return false
  }

  private static func pendingApprovalCommand(from metadata: ConversationSourceState.SessionMetadata) -> String? {
    guard let command = metadata.pendingApprovalCommand?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !command.isEmpty
    else { return nil }
    let cleaned = stripKnownShellWrapperPrefix(command)
    return cleaned.isEmpty ? nil : cleaned
  }

  private static func commandFromToolMessage(_ message: TranscriptMessage) -> String {
    stripKnownShellWrapperPrefix(message.content)
  }

  private static func isToolLikeMessage(_ message: TranscriptMessage) -> Bool {
    message.type == .tool || message.type == .shell
  }

  private static func isWorkerLinkedToolMessage(_ message: TranscriptMessage) -> Bool {
    guard isToolLikeMessage(message), linkedWorkerID(for: message) != nil else { return false }

    let toolName = message.toolName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if toolName == "task" || toolName == "wait" || toolName == "handoff" {
      return true
    }

    return (message.toolInput?["receiver_thread_ids"] as? [String])?.isEmpty == false
  }

  private static func linkedWorkerID(for message: TranscriptMessage) -> String? {
    if let explicitSubagentID = message.toolInput?["subagent_id"] as? String,
       !explicitSubagentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return explicitSubagentID
    }

    if let receiverThreadID = message.toolInput?["receiver_thread_id"] as? String,
       !receiverThreadID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return receiverThreadID
    }

    if let receiverThreadIDs = message.toolInput?["receiver_thread_ids"] as? [String],
       receiverThreadIDs.count == 1
    {
      let onlyThreadID = receiverThreadIDs[0].trimmingCharacters(in: .whitespacesAndNewlines)
      return onlyThreadID.isEmpty ? nil : onlyThreadID
    }

    return nil
  }

  private static func stripKnownShellWrapperPrefix(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return trimmed }

    let pattern =
      #"^(?:/usr/bin/env\s+)?(?:\S+\/)?(?:sh|bash|zsh|fish|ksh|dash|csh|tcsh|pwsh(?:\.exe)?|powershell(?:\.exe)?|cmd(?:\.exe)?)\s+(?:-ilc|-lc|-ic|-c|/c|/C|-Command)\s+"#
    if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
      let range = NSRange(trimmed.startIndex ..< trimmed.endIndex, in: trimmed)
      if let match = regex.firstMatch(in: trimmed, options: [], range: range),
         match.range.location == 0,
         let prefixRange = Range(match.range, in: trimmed)
      {
        let command = String(trimmed[prefixRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimOuterQuotes(command)
      }
    }

    return trimOuterQuotes(trimmed)
  }

  private static func trimOuterQuotes(_ value: String) -> String {
    guard value.count >= 2 else { return value }
    if value.hasPrefix("\""), value.hasSuffix("\"") {
      return String(value.dropFirst().dropLast())
    }
    if value.hasPrefix("'"), value.hasSuffix("'") {
      return String(value.dropFirst().dropLast())
    }
    return value
  }

  private static func commandMentioned(_ content: String, pendingCommand: String) -> Bool {
    let normalizedContent = normalizeCommandText(content)
    let normalizedCommand = normalizeCommandText(pendingCommand)
    guard !normalizedCommand.isEmpty else { return false }
    return normalizedContent.contains(normalizedCommand)
  }

  private static func commandsLikelyMatch(_ lhs: String, _ rhs: String) -> Bool {
    let normalizedLHS = normalizeCommandText(lhs)
    let normalizedRHS = normalizeCommandText(rhs)
    guard !normalizedLHS.isEmpty, !normalizedRHS.isEmpty else { return false }
    return normalizedLHS == normalizedRHS
      || normalizedLHS.contains(normalizedRHS)
      || normalizedRHS.contains(normalizedLHS)
  }

  private static func normalizeCommandText(_ value: String) -> String {
    stripKnownShellWrapperPrefix(value)
      .lowercased()
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }

  private static func splitFocusedTurnMessages(_ messages: [TranscriptMessage]) -> FocusedTurnSplit {
    var leading: [TranscriptMessage] = []
    var toolZone: [TranscriptMessage] = []
    var trailing: [TranscriptMessage] = []
    var foundFirstTool = false
    var lastToolIndex = -1
    var toolCount = 0

    for (index, message) in messages.enumerated() where isToolLikeMessage(message) {
      lastToolIndex = index
      toolCount += 1
    }

    for (index, message) in messages.enumerated() {
      if isToolLikeMessage(message) {
        foundFirstTool = true
        toolZone.append(message)
      } else if !foundFirstTool {
        leading.append(message)
      } else if index > lastToolIndex {
        trailing.append(message)
      } else {
        toolZone.append(message)
      }
    }

    return FocusedTurnSplit(leading: leading, toolZone: toolZone, trailing: trailing, toolCount: toolCount)
  }

  /// Split tool zone messages into segments: work groups (tool + thinking) and breakers (assistant).
  /// Each work group can independently collapse via its own rollup.
  private static func segmentToolZone(_ messages: [TranscriptMessage]) -> [ToolZoneSegment] {
    var segments: [ToolZoneSegment] = []
    var currentGroup: [TranscriptMessage] = []

    for message in messages {
      if isToolLikeMessage(message) || message.type == .thinking {
        currentGroup.append(message)
      } else {
        // Breaker: assistant / user / steer
        if !currentGroup.isEmpty {
          segments.append(.workGroup(currentGroup))
          currentGroup = []
        }
        segments.append(.breaker(message))
      }
    }

    if !currentGroup.isEmpty {
      segments.append(.workGroup(currentGroup))
    }

    return segments
  }

  /// Build a tool breakdown from hidden messages — grouped by name, sorted by frequency.
  private static func toolBreakdown(from messages: [TranscriptMessage]) -> [ToolBreakdownEntry] {
    var countMap: [String: Int] = [:]
    var iconMap: [String: String] = [:]
    var colorMap: [String: String] = [:]

    for msg in messages where isToolLikeMessage(msg) {
      let name = msg.toolName ?? (msg.type == .shell ? "bash" : "tool")
      countMap[name, default: 0] += 1
      if iconMap[name] == nil {
        iconMap[name] = resolveToolIcon(name)
        colorMap[name] = resolveToolColorKey(name)
      }
    }

    return countMap
      .sorted { $0.value > $1.value }
      .map { name, count in
        ToolBreakdownEntry(
          name: name,
          icon: iconMap[name] ?? "gearshape",
          colorKey: colorMap[name] ?? "secondary",
          count: count
        )
      }
  }

  private static func resolveToolIcon(_ name: String) -> String {
    let normalized = name.lowercased().split(separator: ":").last.map(String.init) ?? name.lowercased()
    if ["todowrite", "todo_write", "taskcreate", "taskupdate", "tasklist", "taskget", "update_plan"]
      .contains(normalized)
    {
      return "checklist"
    }
    if name.hasPrefix("mcp__") { return "puzzlepiece.extension" }
    switch name.lowercased() {
      case "bash": return "terminal"
      case "read": return "doc.plaintext"
      case "edit", "write", "notebookedit": return "pencil.line"
      case "glob", "grep": return "magnifyingglass"
      case "task": return "bolt.fill"
      case "webfetch", "websearch": return "globe"
      case "skill": return "wand.and.stars"
      case "enterplanmode", "exitplanmode": return "map"
      case "todowrite", "todo_write", "taskcreate", "taskupdate", "tasklist", "taskget", "update_plan":
        return "checklist"
      case "askuserquestion": return "questionmark.bubble"
      case "mcp_approval": return "shield.lefthalf.filled"
      default: return "gearshape"
    }
  }

  private static func resolveToolColorKey(_ name: String) -> String {
    let normalized = name.lowercased().split(separator: ":").last.map(String.init) ?? name.lowercased()
    if ["todowrite", "todo_write", "taskcreate", "taskupdate", "tasklist", "taskget", "update_plan"]
      .contains(normalized)
    {
      return "todo"
    }
    if name.hasPrefix("mcp__") { return "mcp" }
    switch name.lowercased() {
      case "bash": return "bash"
      case "read": return "read"
      case "edit", "write", "notebookedit": return "write"
      case "glob", "grep": return "search"
      case "task": return "task"
      case "webfetch", "websearch": return "web"
      case "skill": return "skill"
      case "enterplanmode", "exitplanmode": return "plan"
      case "todowrite", "todo_write", "taskcreate", "taskupdate", "tasklist", "taskget", "update_plan":
        return "todo"
      case "askuserquestion": return "question"
      case "mcp_approval": return "question"
      default: return "secondary"
    }
  }

  private static func makeRow(
    id: TimelineRowID,
    kind: TimelineRowKind,
    payload: TimelineRowPayload,
    context: ProjectionContext
  ) -> TimelineRow {
    let renderHash = renderHash(kind: kind, payload: payload, context: context)
    let layoutHash = layoutHash(
      kind: kind,
      payload: payload,
      renderHash: renderHash,
      widthBucket: context.ui.widthBucket
    )
    return TimelineRow(id: id, kind: kind, payload: payload, layoutHash: layoutHash, renderHash: renderHash)
  }

  private static func renderHash(
    kind: TimelineRowKind,
    payload: TimelineRowPayload,
    context: ProjectionContext
  ) -> Int {
    var hasher = Hasher()
    hasher.combine(kind)
    hasher.combine(payload)

    switch kind {
      case .loadMore:
        hasher.combine(context.source.metadata.remainingLoadCount)

      case .messageCount:
        hasher.combine(context.source.messages.count)
        hasher.combine(context.source.metadata.messageCount)

      case .message:
        if case let .message(id, _) = payload, let message = context.messagesByID[id] {
          combineRenderable(message: message, into: &hasher)
        }

      case .tool:
        if case let .tool(id) = payload, let message = context.messagesByID[id] {
          combineRenderable(message: message, into: &hasher)
          hasher.combine(context.ui.expandedToolCards.contains(id))
        }

      case .workerEvent:
        if case let .workerEvent(id) = payload, let message = context.messagesByID[id] {
          combineRenderable(message: message, into: &hasher)
        }

      case .turnHeader:
        if case let .turnHeader(turnID, _, _) = payload, let turn = context.turnsByID[turnID] {
          combineTurnHeader(turn: turn, into: &hasher)
        }

      case .rollupSummary:
        if case let .rollupSummary(id, hiddenCount, totalToolCount, isExpanded, breakdown, hiddenMessageIDs) = payload {
          hasher.combine(id)
          hasher.combine(hiddenCount)
          hasher.combine(totalToolCount)
          hasher.combine(isExpanded)
          hasher.combine(breakdown)
          hasher.combine(hiddenMessageIDs)
        }

      case .liveIndicator:
        let metadata = context.source.metadata
        hasher.combine(metadata.workStatus.rawValue)
        combineTextSignature(metadata.currentTool, into: &hasher)
        combineTextSignature(metadata.currentPrompt, into: &hasher)
        combineTextSignature(metadata.pendingToolName, into: &hasher)
        combineTextSignature(metadata.pendingApprovalCommand, into: &hasher)
        combineTextSignature(metadata.pendingPermissionDetail, into: &hasher)

      case .approvalCard:
        let metadata = context.source.metadata
        hasher.combine(metadata.approvalMode)
        combineTextSignature(metadata.pendingToolName, into: &hasher)
        combineTextSignature(metadata.pendingApprovalCommand, into: &hasher)
        combineTextSignature(metadata.pendingQuestion, into: &hasher)
        hasher.combine(metadata.pendingApprovalId)
        hasher.combine(metadata.isDirectSession)

      case .workerOrchestration:
        if case let .workerOrchestration(turnID, workerIDs) = payload {
          hasher.combine(turnID)
          hasher.combine(workerIDs)
        }

      case .bottomSpacer:
        hasher.combine(32)

      case .liveProgress:
        if case let .liveProgress(currentTool, completedCount, elapsedTime) = payload {
          combineTextSignature(currentTool, into: &hasher)
          hasher.combine(completedCount)
          hasher.combine(Int(elapsedTime * 10))
        }

      case .collapsedTurn:
        if case let .collapsedTurn(turnID, userPreview, assistantPreview, toolCount, totalDuration) = payload {
          hasher.combine(turnID)
          combineTextSignature(userPreview, into: &hasher)
          combineTextSignature(assistantPreview, into: &hasher)
          hasher.combine(toolCount)
          if let d = totalDuration { hasher.combine(Int(d * 10)) }
        }
    }

    return hasher.finalize()
  }

  private static func combineTurnHeader(turn: TurnSummary, into hasher: inout Hasher) {
    hasher.combine(turn.id)
    hasher.combine(turn.turnNumber)
    hasher.combine(turn.toolsUsed)
    hasher.combine(turn.changedFiles)
    hasher.combine(turn.tokenDelta)
    if let usage = turn.tokenUsage {
      hasher.combine(usage.inputTokens)
      hasher.combine(usage.outputTokens)
      hasher.combine(usage.cachedTokens)
      hasher.combine(usage.contextWindow)
    }
    switch turn.status {
      case .active:
        hasher.combine(0)
      case .completed:
        hasher.combine(1)
      case .failed:
        hasher.combine(2)
    }
  }

  private static func layoutHash(
    kind: TimelineRowKind,
    payload: TimelineRowPayload,
    renderHash: Int,
    widthBucket: Int
  ) -> Int {
    var hasher = Hasher()
    hasher.combine(kind)
    hasher.combine(payload)
    hasher.combine(renderHash)
    hasher.combine(widthBucket)
    return hasher.finalize()
  }

  private static func buildDiff(
    previousRows: [TimelineRow],
    nextRows: [TimelineRow]
  ) -> (ProjectionDiff, Set<TimelineRowID>) {
    guard !previousRows.isEmpty else {
      let insertedIndices = Array(nextRows.indices)
      let insertedIDs = Set(nextRows.map(\.id))
      return (
        ProjectionDiff(insertions: insertedIndices, deletions: [], moves: [], reloads: []),
        insertedIDs
      )
    }

    let oldIndexByID = Dictionary(uniqueKeysWithValues: previousRows.enumerated().map { ($1.id, $0) })
    let newIndexByID = Dictionary(uniqueKeysWithValues: nextRows.enumerated().map { ($1.id, $0) })

    var insertions: [Int] = []
    var deletions: [Int] = []
    var reloads: [Int] = []
    var dirtyRowIDs = Set<TimelineRowID>()

    for (index, row) in nextRows.enumerated() where oldIndexByID[row.id] == nil {
      insertions.append(index)
      dirtyRowIDs.insert(row.id)
    }

    for (index, row) in previousRows.enumerated() where newIndexByID[row.id] == nil {
      deletions.append(index)
    }

    for (id, oldIndex) in oldIndexByID {
      guard let newIndex = newIndexByID[id] else { continue }
      let oldRow = previousRows[oldIndex]
      let newRow = nextRows[newIndex]
      if oldRow.renderHash != newRow.renderHash {
        reloads.append(newIndex)
        dirtyRowIDs.insert(id)
      }
      if oldRow.layoutHash != newRow.layoutHash {
        dirtyRowIDs.insert(id)
      }
    }

    insertions.sort()
    deletions.sort(by: >)
    reloads.sort()

    return (
      ProjectionDiff(
        insertions: insertions,
        deletions: deletions,
        moves: [],
        reloads: reloads
      ),
      dirtyRowIDs
    )
  }

  private static func combineRenderable(message: TranscriptMessage, into hasher: inout Hasher) {
    hasher.combine(message.id)
    hasher.combine(message.type.rawValue)
    hasher.combine(message.contentSignature)
  }

  private static func combineTextSignature(_ text: String?, into hasher: inout Hasher) {
    guard let text else {
      hasher.combine(0)
      return
    }
    let utf8 = text.utf8
    let byteCount = utf8.count          // O(1) for native Swift strings
    hasher.combine(byteCount)

    // Sample prefix/suffix via UTF-8 byte offsets — O(k) not O(n).
    let prefixEnd = utf8.index(utf8.startIndex, offsetBy: min(256, byteCount))
    hasher.combine(text[utf8.startIndex ..< prefixEnd].hashValue)

    let suffixStart = utf8.index(utf8.endIndex, offsetBy: -min(64, byteCount))
    hasher.combine(text[suffixStart ..< utf8.endIndex].hashValue)
  }

  private struct ProjectionContext {
    let source: ConversationSourceState
    let ui: ConversationUIState
    let messagesByID: [String: TranscriptMessage]
    let turnsByID: [String: TurnSummary]

    init(source: ConversationSourceState, ui: ConversationUIState) {
      self.source = source
      self.ui = ui
      messagesByID = Dictionary(uniqueKeysWithValues: source.messages.map { ($0.id, $0) })
      turnsByID = Dictionary(uniqueKeysWithValues: source.turns.map { ($0.id, $0) })
    }
  }
}
