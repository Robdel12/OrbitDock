//
//  ConversationTimelineProjector.swift
//  OrbitDock
//
//  Pure projector that produces deterministic flat timeline rows + structural diff.
//

import Foundation

private struct ProjectionMessageMeta {
  let turnsAfter: Int?
  let nthUserMessage: Int?
}

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
          appendMessageRow(message, toolRowsEnabled: false, context: context, rows: &rows)
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
        payload: .turnHeader(turnID: turn.id),
        context: context
      )
    )

    let split = splitFocusedTurnMessages(turn.messages)
    for message in split.leading {
      appendMessageRow(message, toolRowsEnabled: true, context: context, rows: &rows)
    }

    if !split.toolZone.isEmpty {
      let segments = segmentToolZone(split.toolZone)

      for (groupIndex, segment) in segments.enumerated() {
        switch segment {
          case let .breaker(message):
            appendMessageRow(message, toolRowsEnabled: true, context: context, rows: &rows)

          case let .workGroup(messages):
            let groupID = "\(TimelineRowID.turnRollupKey(turn.id)):g\(groupIndex)"
            let isExpanded = context.ui.expandedRollups.contains(groupID)
            let toolCount = messages.filter { $0.type == .tool }.count

            guard messages.count >= focusedCollapseThreshold else {
              // Too few items — show all, no rollup
              for msg in messages {
                appendMessageRow(msg, toolRowsEnabled: true, context: context, rows: &rows)
              }
              continue
            }

            let visibleTailCount = min(focusedVisibleToolTail, max(1, messages.count - 1))
            let hiddenCount = messages.count - visibleTailCount
            let hiddenToolCount = messages.prefix(hiddenCount).filter { $0.type == .tool }.count
            let breakdown = toolBreakdown(from: Array(messages.prefix(hiddenCount)))

            rows.append(
              makeRow(
                id: .rollupSummary(groupID),
                kind: .rollupSummary,
                payload: .rollupSummary(
                  id: groupID,
                  hiddenCount: hiddenToolCount,
                  totalToolCount: toolCount,
                  isExpanded: isExpanded,
                  breakdown: breakdown
                ),
                context: context
              )
            )

            let visibleMessages = isExpanded ? messages : Array(messages.suffix(visibleTailCount))
            for msg in visibleMessages {
              appendMessageRow(msg, toolRowsEnabled: true, context: context, rows: &rows)
            }
        }
      }
    }

    for message in split.trailing {
      appendMessageRow(message, toolRowsEnabled: true, context: context, rows: &rows)
    }
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

    let isToolRow = toolRowsEnabled && message.type == .tool
    rows.append(
      makeRow(
        id: isToolRow ? .tool(message.id) : .message(message.id),
        kind: isToolRow ? .tool : .message,
        payload: isToolRow ? .tool(id: message.id) : .message(id: message.id),
        context: context
      )
    )
  }

  private static func splitFocusedTurnMessages(_ messages: [TranscriptMessage]) -> FocusedTurnSplit {
    var leading: [TranscriptMessage] = []
    var toolZone: [TranscriptMessage] = []
    var trailing: [TranscriptMessage] = []
    var foundFirstTool = false
    var lastToolIndex = -1
    var toolCount = 0

    for (index, message) in messages.enumerated() where message.type == .tool {
      lastToolIndex = index
      toolCount += 1
    }

    for (index, message) in messages.enumerated() {
      if message.type == .tool {
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
      if message.type == .tool || message.type == .thinking {
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

    for msg in messages where msg.type == .tool {
      let name = msg.toolName ?? "tool"
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
      case "taskcreate", "taskupdate", "tasklist", "taskget": return "checklist"
      case "askuserquestion": return "questionmark.bubble"
      default: return "gearshape"
    }
  }

  private static func resolveToolColorKey(_ name: String) -> String {
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
      case "taskcreate", "taskupdate", "tasklist", "taskget": return "todo"
      case "askuserquestion": return "question"
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
        if case let .message(id) = payload, let message = context.messagesByID[id] {
          combineRenderable(message: message, into: &hasher)
          let meta = context.messageMetaByID[id]
          hasher.combine(meta?.turnsAfter)
          hasher.combine(meta?.nthUserMessage)
        }

      case .tool:
        if case let .tool(id) = payload, let message = context.messagesByID[id] {
          combineRenderable(message: message, into: &hasher)
          hasher.combine(context.ui.expandedToolCards.contains(id))
        }

      case .turnHeader:
        if case let .turnHeader(turnID) = payload, let turn = context.turnsByID[turnID] {
          combineTurnHeader(turn: turn, into: &hasher)
        }

      case .rollupSummary:
        if case let .rollupSummary(id, hiddenCount, totalToolCount, isExpanded, breakdown) = payload {
          hasher.combine(id)
          hasher.combine(hiddenCount)
          hasher.combine(totalToolCount)
          hasher.combine(isExpanded)
          hasher.combine(breakdown)
        }

      case .liveIndicator:
        let metadata = context.source.metadata
        hasher.combine(metadata.workStatus.rawValue)
        combineTextSignature(metadata.currentTool, into: &hasher)
        combineTextSignature(metadata.currentPrompt, into: &hasher)
        combineTextSignature(metadata.pendingToolName, into: &hasher)
        combineTextSignature(metadata.pendingToolInput, into: &hasher)

      case .approvalCard:
        let metadata = context.source.metadata
        hasher.combine(metadata.approvalMode)
        combineTextSignature(metadata.pendingToolName, into: &hasher)
        combineTextSignature(metadata.pendingToolInput, into: &hasher)
        combineTextSignature(metadata.pendingQuestion, into: &hasher)
        hasher.combine(metadata.pendingApprovalId)
        hasher.combine(metadata.isDirectSession)

      case .bottomSpacer:
        hasher.combine(32)
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
    combineTextSignature(message.content, into: &hasher)
    hasher.combine(message.toolName)
    combineTextSignature(message.toolOutput, into: &hasher)
    hasher.combine(message.toolDuration)
    hasher.combine(message.inputTokens)
    hasher.combine(message.outputTokens)
    hasher.combine(message.isInProgress)
    combineTextSignature(message.thinking, into: &hasher)
    hasher.combine(message.images.count)
    for image in message.images {
      hasher.combine(image.id)
      hasher.combine(image.mimeType)
      hasher.combine(image.byteCount)
    }
  }

  private static func combineTextSignature(_ text: String?, into hasher: inout Hasher) {
    guard let text else {
      hasher.combine(0)
      return
    }
    hasher.combine(text.count)
    hasher.combine(String(text.prefix(256)))
    hasher.combine(String(text.suffix(64)))
  }

  private struct ProjectionContext {
    let source: ConversationSourceState
    let ui: ConversationUIState
    let messagesByID: [String: TranscriptMessage]
    let turnsByID: [String: TurnSummary]
    let messageMetaByID: [String: ProjectionMessageMeta]

    init(source: ConversationSourceState, ui: ConversationUIState) {
      self.source = source
      self.ui = ui
      messagesByID = Dictionary(uniqueKeysWithValues: source.messages.map { ($0.id, $0) })
      turnsByID = Dictionary(uniqueKeysWithValues: source.turns.map { ($0.id, $0) })
      messageMetaByID = Self.computeMessageMetadata(source.messages)
    }

    private static func computeMessageMetadata(_ messages: [TranscriptMessage]) -> [String: ProjectionMessageMeta] {
      var result: [String: ProjectionMessageMeta] = [:]
      result.reserveCapacity(messages.count)

      var userCount = 0
      var userIndices: [Int] = []
      for (index, message) in messages.enumerated() {
        if message.type == .user {
          result[message.id] = ProjectionMessageMeta(turnsAfter: 0, nthUserMessage: userCount)
          userCount += 1
          userIndices.append(index)
        } else {
          result[message.id] = ProjectionMessageMeta(turnsAfter: nil, nthUserMessage: nil)
        }
      }

      for (rank, messageIndex) in userIndices.enumerated() {
        let userMessagesAfter = userIndices.count - rank - 1
        let turnsAfter: Int
        if userMessagesAfter > 0 {
          turnsAfter = userMessagesAfter
        } else if messageIndex + 1 < messages.count {
          let hasResponseAfter = messages[(messageIndex + 1)...].contains { $0.type != .user }
          turnsAfter = hasResponseAfter ? 1 : 0
        } else {
          turnsAfter = 0
        }

        let id = messages[messageIndex].id
        let existing = result[id]
        result[id] = ProjectionMessageMeta(
          turnsAfter: turnsAfter > 0 ? turnsAfter : nil,
          nthUserMessage: existing?.nthUserMessage
        )
      }

      return result
    }
  }
}
