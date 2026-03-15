//
//  TimelineDataSource.swift
//  OrbitDock
//
//  Manages the flat array of ServerConversationRowEntry for the timeline.
//  Maps each row to a cell type, computes diffs for incremental updates.
//

import Foundation

enum TimelineCellType {
  case message    // user, assistant, system
  case thinking   // reasoning trace
  case toolCard   // tool call with ServerToolDisplay
  case activityGroup // collapsible group of tools
  case approval   // permission/approval request
  case question   // question prompt
  case worker     // worker/subagent status
  case plan       // plan entry
  case hook       // hook notification
  case handoff    // handoff request

  static func from(_ row: ServerConversationRow) -> TimelineCellType {
    switch row {
    case .user, .assistant, .system:
      return .message
    case .thinking:
      return .thinking
    case .tool:
      return .toolCard
    case .activityGroup:
      return .activityGroup
    case .approval:
      return .approval
    case .question:
      return .question
    case .worker:
      return .worker
    case .plan:
      return .plan
    case .hook:
      return .hook
    case .handoff:
      return .handoff
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
    insertedIndexes: IndexSet(),
    removedIndexes: IndexSet(),
    updatedIndexes: IndexSet(),
    movedPairs: [],
    isFullReload: true
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

  /// Apply new entries from ConversationStore, returning a diff for incremental updates.
  func apply(_ newEntries: [ServerConversationRowEntry]) -> TimelineDiff {
    let oldIDs = entries.map(\.id)
    let newIDs = newEntries.map(\.id)

    // Fast path: if IDs haven't changed, check for content updates
    if oldIDs == newIDs {
      var updatedIndexes = IndexSet()
      for (index, newEntry) in newEntries.enumerated() {
        let oldEntry = entries[index]
        if !rowsEqual(oldEntry.row, newEntry.row) {
          updatedIndexes.insert(index)
        }
      }
      entries = newEntries
      rebuildIndex()
      if updatedIndexes.isEmpty {
        return TimelineDiff(insertedIndexes: IndexSet(), removedIndexes: IndexSet(), updatedIndexes: IndexSet(), movedPairs: [], isFullReload: false)
      }
      return TimelineDiff(insertedIndexes: IndexSet(), removedIndexes: IndexSet(), updatedIndexes: updatedIndexes, movedPairs: [], isFullReload: false)
    }

    // Structural change — full reload for simplicity
    entries = newEntries
    rebuildIndex()
    return .fullReload
  }

  private func rebuildIndex() {
    entryIDToIndex = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($1.id, $0) })
  }

  private func rowsEqual(_ lhs: ServerConversationRow, _ rhs: ServerConversationRow) -> Bool {
    // Compare by encoding to JSON — not ideal for performance but correct.
    // For hot paths, we rely on the revision counter to avoid unnecessary calls.
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
