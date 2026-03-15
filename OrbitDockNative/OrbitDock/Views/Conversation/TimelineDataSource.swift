//
//  TimelineDataSource.swift
//  OrbitDock
//
//  Manages the flat array of ServerConversationRowEntry for the timeline.
//  In focused mode, groups consecutive tool rows into activity groups.
//

import Foundation

enum TimelineCellType {
  case message
  case thinking
  case toolCard
  case activityGroup
  case approval
  case question
  case worker
  case plan
  case hook
  case handoff

  static func from(_ row: ServerConversationRow) -> TimelineCellType {
    switch row {
    case .user, .assistant, .system: .message
    case .thinking: .thinking
    case .tool: .toolCard
    case .activityGroup: .activityGroup
    case .approval: .approval
    case .question: .question
    case .worker: .worker
    case .plan: .plan
    case .hook: .hook
    case .handoff: .handoff
    }
  }
}

struct TimelineDiff {
  let insertedIndexes: IndexSet
  let removedIndexes: IndexSet
  let updatedIndexes: IndexSet
  let movedPairs: [(from: Int, to: Int)]
  let isFullReload: Bool

  static let fullReload = TimelineDiff(
    insertedIndexes: IndexSet(), removedIndexes: IndexSet(),
    updatedIndexes: IndexSet(), movedPairs: [], isFullReload: true
  )
}

@MainActor
final class TimelineDataSource {
  private(set) var entries: [ServerConversationRowEntry] = []
  private var entryIDToIndex: [String: Int] = [:]

  var count: Int { entries.count }

  func entry(at index: Int) -> ServerConversationRowEntry? {
    guard index >= 0, index < entries.count else { return nil }
    return entries[index]
  }

  func cellType(at index: Int) -> TimelineCellType? {
    guard let entry = entry(at: index) else { return nil }
    return TimelineCellType.from(entry.row)
  }

  /// Apply new entries, optionally grouping tools in focused mode.
  func apply(_ newEntries: [ServerConversationRowEntry], viewMode: ChatViewMode = .verbose) -> TimelineDiff {
    let processed = viewMode == .focused
      ? groupToolRuns(newEntries)
      : newEntries

    let oldIDs = entries.map(\.id)
    let newIDs = processed.map(\.id)

    if oldIDs == newIDs {
      var updatedIndexes = IndexSet()
      for (index, newEntry) in processed.enumerated() {
        if !rowsEqual(entries[index].row, newEntry.row) {
          updatedIndexes.insert(index)
        }
      }
      entries = processed
      rebuildIndex()
      if updatedIndexes.isEmpty {
        return TimelineDiff(insertedIndexes: IndexSet(), removedIndexes: IndexSet(),
                            updatedIndexes: IndexSet(), movedPairs: [], isFullReload: false)
      }
      return TimelineDiff(insertedIndexes: IndexSet(), removedIndexes: IndexSet(),
                          updatedIndexes: updatedIndexes, movedPairs: [], isFullReload: false)
    }

    entries = processed
    rebuildIndex()
    return .fullReload
  }

  // MARK: - Tool Grouping

  /// In focused mode, consecutive tool/worker/plan/hook rows between message rows
  /// collapse into synthetic activityGroup entries.
  private func groupToolRuns(_ rawEntries: [ServerConversationRowEntry]) -> [ServerConversationRowEntry] {
    var result: [ServerConversationRowEntry] = []
    var toolBuffer: [ServerConversationToolRow] = []
    var bufferSessionId = ""
    var bufferStartSequence: UInt64 = 0

    func flushBuffer() {
      guard !toolBuffer.isEmpty else { return }
      if toolBuffer.count == 1 {
        // Single tool — show as individual card
        let tool = toolBuffer[0]
        result.append(ServerConversationRowEntry(
          sessionId: bufferSessionId,
          sequence: bufferStartSequence,
          turnId: nil,
          row: .tool(tool)
        ))
      } else {
        // Multiple tools — wrap in activity group
        let allCompleted = toolBuffer.allSatisfy { $0.status == .completed }
        let groupStatus: ServerConversationToolStatus = allCompleted ? .completed : .running
        let group = ServerConversationActivityGroupRow(
          id: "group:\(toolBuffer.first!.id)",
          groupKind: .toolBlock,
          title: "\(toolBuffer.count) tools",
          subtitle: nil,
          summary: toolBuffer.map(\.title).joined(separator: ", "),
          childCount: toolBuffer.count,
          children: toolBuffer,
          turnId: nil,
          groupingKey: nil,
          status: groupStatus,
          family: nil,
          renderHints: ServerConversationRenderHints()
        )
        result.append(ServerConversationRowEntry(
          sessionId: bufferSessionId,
          sequence: bufferStartSequence,
          turnId: nil,
          row: .activityGroup(group)
        ))
      }
      toolBuffer.removeAll()
    }

    for entry in rawEntries {
      switch entry.row {
      case let .tool(toolRow):
        if toolBuffer.isEmpty {
          bufferSessionId = entry.sessionId
          bufferStartSequence = entry.sequence
        }
        toolBuffer.append(toolRow)

      case .worker, .plan, .hook, .handoff:
        // These are lightweight — keep them individual but flush any tool buffer first
        flushBuffer()
        result.append(entry)

      default:
        // Message, thinking, approval, question, system — flush tool buffer
        flushBuffer()
        result.append(entry)
      }
    }

    flushBuffer()
    return result
  }

  // MARK: - Private

  private func rebuildIndex() {
    entryIDToIndex = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($1.id, $0) })
  }

  private func rowsEqual(_ lhs: ServerConversationRow, _ rhs: ServerConversationRow) -> Bool {
    switch (lhs, rhs) {
    case let (.assistant(l), .assistant(r)),
         let (.user(l), .user(r)),
         let (.thinking(l), .thinking(r)),
         let (.system(l), .system(r)):
      return l.id == r.id && l.content == r.content && l.isStreaming == r.isStreaming
    case let (.tool(l), .tool(r)):
      return l.id == r.id && l.status == r.status && l.summary == r.summary
        && l.toolDisplay?.summary == r.toolDisplay?.summary
    case let (.activityGroup(l), .activityGroup(r)):
      return l.id == r.id && l.status == r.status && l.childCount == r.childCount
    default:
      return false
    }
  }
}
