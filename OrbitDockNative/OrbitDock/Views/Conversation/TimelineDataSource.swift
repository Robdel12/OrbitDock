//
//  TimelineDataSource.swift
//  OrbitDock
//
//  In focused mode, groups consecutive tool rows into activity groups.
//  Projection caches the derived structure so streamed row updates can patch
//  affected display rows without rebuilding the whole timeline.
//

import Foundation

enum TimelineDataSource {
  struct Projection {
    private(set) var displayedEntries: [ServerConversationRowEntry]

    private let directDisplayIndexByRowID: [String: Int]
    private let groupIndexByChildRowID: [String: Int]
    private let groupSpecsByIndex: [Int: ToolGroupSpec]

    static func make(
      entries: [ServerConversationRowEntry],
      viewMode: ChatViewMode
    ) -> Projection {
      guard viewMode == .focused else {
        let directIndexByRowID = TimelineDataSource.displayIndexByRowID(entries)
        return Projection(
          displayedEntries: entries,
          directDisplayIndexByRowID: directIndexByRowID,
          groupIndexByChildRowID: [:],
          groupSpecsByIndex: [:]
        )
      }

      var displayedEntries: [ServerConversationRowEntry] = []
      var directDisplayIndexByRowID: [String: Int] = [:]
      var groupIndexByChildRowID: [String: Int] = [:]
      var groupSpecsByIndex: [Int: ToolGroupSpec] = [:]

      var toolBuffer: [ToolBufferItem] = []

      func flushBuffer() {
        guard !toolBuffer.isEmpty else { return }

        if toolBuffer.count == 1 {
          let tool = toolBuffer[0]
          let displayIndex = displayedEntries.count
          displayedEntries.append(tool.entry)
          directDisplayIndexByRowID[tool.entry.id] = displayIndex
          toolBuffer.removeAll()
          return
        }

        let latestTool = toolBuffer[toolBuffer.count - 1]
        let archivedTools = Array(toolBuffer.dropLast())

        let latestToolIndex = displayedEntries.count
        displayedEntries.append(latestTool.entry)
        directDisplayIndexByRowID[latestTool.entry.id] = latestToolIndex

        let groupIndex = displayedEntries.count
        let spec = ToolGroupSpec(
          sessionId: latestTool.entry.sessionId,
          sequence: toolBuffer[0].entry.sequence,
          turnId: nil,
          latestToolID: latestTool.entry.id,
          archivedToolIDs: archivedTools.map(\.entry.id)
        )

        displayedEntries.append(makeActivityGroupEntry(
          spec: spec,
          rawEntriesByID: TimelineDataSource.entryDictionary(toolBuffer.map(\.entry))
        ))
        groupSpecsByIndex[groupIndex] = spec

        for child in archivedTools {
          groupIndexByChildRowID[child.entry.id] = groupIndex
        }

        toolBuffer.removeAll()
      }

      for entry in entries {
        switch entry.row {
          case .tool, .commandExecution:
            toolBuffer.append(ToolBufferItem(entry: entry))

          case .context, .notice, .shellCommand, .task, .worker, .plan, .hook, .handoff:
            flushBuffer()
            let displayIndex = displayedEntries.count
            displayedEntries.append(entry)
            directDisplayIndexByRowID[entry.id] = displayIndex

          default:
            flushBuffer()
            let displayIndex = displayedEntries.count
            displayedEntries.append(entry)
            directDisplayIndexByRowID[entry.id] = displayIndex
        }
      }

      flushBuffer()

      return Projection(
        displayedEntries: displayedEntries,
        directDisplayIndexByRowID: directDisplayIndexByRowID,
        groupIndexByChildRowID: groupIndexByChildRowID,
        groupSpecsByIndex: groupSpecsByIndex
      )
    }

    mutating func applyContentUpdates(
      changedEntries: [ServerConversationRowEntry]
    ) {
      guard !changedEntries.isEmpty else { return }

      var updatedEntries = displayedEntries
      let changedEntriesByID = TimelineDataSource.entryDictionary(changedEntries)
      var dirtyGroupIndices: Set<Int> = []

      for changedEntry in changedEntries {
        if let displayIndex = directDisplayIndexByRowID[changedEntry.id] {
          updatedEntries[displayIndex] = changedEntry
        }

        if let groupIndex = groupIndexByChildRowID[changedEntry.id] {
          dirtyGroupIndices.insert(groupIndex)
        }
      }

      for groupIndex in dirtyGroupIndices {
        guard let spec = groupSpecsByIndex[groupIndex] else { continue }
        updatedEntries[groupIndex] = makeActivityGroupEntry(
          spec: spec,
          rawEntriesByID: changedEntriesByID,
          fallbackEntries: displayedEntries
        )
      }

      displayedEntries = updatedEntries
    }

    var count: Int {
      displayedEntries.count
    }

    func suffix(_ maxLength: Int) -> ArraySlice<ServerConversationRowEntry> {
      displayedEntries.suffix(maxLength)
    }

    func displayAnchorID(for rowID: String) -> String? {
      displayIndex(for: rowID).flatMap { displayedEntries[$0].id }
    }

    func suffixCountRequiredToRender(rowID: String) -> Int? {
      guard let displayIndex = displayIndex(for: rowID) else { return nil }
      return max(displayedEntries.count - displayIndex, 1)
    }

    private func displayIndex(for rowID: String) -> Int? {
      if let displayIndex = directDisplayIndexByRowID[rowID] {
        return displayIndex
      }

      return groupIndexByChildRowID[rowID]
    }
  }

  private struct ToolBufferItem {
    let entry: ServerConversationRowEntry
  }

  private struct ToolGroupSpec {
    let sessionId: String
    let sequence: UInt64
    let turnId: String?
    let latestToolID: String
    let archivedToolIDs: [String]
  }

  private static func makeActivityGroupEntry(
    spec: ToolGroupSpec,
    rawEntriesByID: [String: ServerConversationRowEntry],
    fallbackEntries: [ServerConversationRowEntry] = []
  ) -> ServerConversationRowEntry {
    let fallbackEntriesByID = entryDictionary(fallbackEntries)
    let archivedTools = spec.archivedToolIDs.compactMap { rowID in
      activityChild(for: rowID, primary: rawEntriesByID, fallback: fallbackEntriesByID)
    }

    let latestTool = activityChild(for: spec.latestToolID, primary: rawEntriesByID, fallback: fallbackEntriesByID)

    let title = archivedTools.count == 1 ? "1 previous action" : "\(archivedTools.count) previous actions"
    let summary = archivedTools.map(activityChildTitle(_:)).joined(separator: ", ")
    let status = groupedActivityStatus(archivedTools)
    let latestFamily = latestTool.flatMap(activityChildFamily(_:))

    return ServerConversationRowEntry(
      sessionId: spec.sessionId,
      sequence: spec.sequence,
      turnId: spec.turnId,
      turnStatus: .active,
      row: .activityGroup(ServerConversationActivityGroupRow(
        id: "group:\(spec.archivedToolIDs.first ?? spec.latestToolID)",
        groupKind: .toolBlock,
        title: title,
        subtitle: nil,
        summary: summary,
        childCount: archivedTools.count,
        children: archivedTools,
        turnId: spec.turnId,
        groupingKey: nil,
        status: status,
        family: latestFamily,
        renderHints: ServerConversationRenderHints()
      ))
    )
  }

  nonisolated private static func activityChild(
    for rowID: String,
    primary: [String: ServerConversationRowEntry],
    fallback: [String: ServerConversationRowEntry]
  ) -> ServerConversationActivityGroupChild? {
    let entry = primary[rowID] ?? fallback[rowID]
    guard let entry else { return nil }
    switch entry.row {
      case let .tool(toolRow):
        return .tool(toolRow)
      case let .commandExecution(commandExecution):
        return .commandExecution(commandExecution)
      default:
        return nil
    }
  }

  nonisolated private static func activityChildTitle(_ child: ServerConversationActivityGroupChild) -> String {
    switch child {
      case let .tool(toolRow):
        return toolRow.title
      case let .commandExecution(commandExecution):
        return commandExecution.commandActions.first.map(commandExecutionActionTitle(_:)) ?? "Run command"
    }
  }

  nonisolated private static func activityChildStatus(_ child: ServerConversationActivityGroupChild) -> ServerConversationToolStatus {
    switch child {
      case let .tool(toolRow):
        return toolRow.status
      case let .commandExecution(commandExecution):
        switch commandExecution.status {
          case .inProgress:
            return .running
          case .completed:
            return .completed
          case .failed:
            return .failed
          case .declined:
            return .blocked
        }
    }
  }

  nonisolated private static func activityChildFamily(_ child: ServerConversationActivityGroupChild) -> ServerConversationToolFamily? {
    switch child {
      case let .tool(toolRow):
        return toolRow.family
      case let .commandExecution(commandExecution):
        return commandExecutionFamily(commandExecution)
    }
  }

  nonisolated private static func groupedActivityStatus(
    _ children: [ServerConversationActivityGroupChild]
  ) -> ServerConversationToolStatus {
    let statuses = children.map(activityChildStatus(_:))

    if statuses.contains(.failed) {
      return .failed
    }

    if statuses.contains(.blocked) {
      return .blocked
    }

    if statuses.contains(.running) || statuses.contains(.pending) || statuses.contains(.needsInput) {
      return .running
    }

    if statuses.contains(.cancelled) {
      return .cancelled
    }

    return .completed
  }

  nonisolated private static func commandExecutionFamily(_ row: ServerConversationCommandExecutionRow) -> ServerConversationToolFamily {
    if row.commandActions.allSatisfy({ $0.type == .read }) {
      return .fileRead
    }
    if row.commandActions.allSatisfy({ $0.type == .search || $0.type == .listFiles }) {
      return .search
    }
    return .shell
  }

  nonisolated private static func commandExecutionActionTitle(_ action: ServerConversationCommandAction) -> String {
    switch action.type {
      case .read:
        return "Read"
      case .search:
        return "Search"
      case .listFiles:
        return "List files"
      case .unknown:
        return "Run command"
    }
  }

  private static func displayIndexByRowID(_ entries: [ServerConversationRowEntry]) -> [String: Int] {
    var indexByID: [String: Int] = [:]
    for (index, entry) in entries.enumerated() {
      indexByID[entry.id] = index
    }
    return indexByID
  }

  private static func entryDictionary(
    _ entries: [ServerConversationRowEntry]
  ) -> [String: ServerConversationRowEntry] {
    var entriesByID: [String: ServerConversationRowEntry] = [:]
    for entry in entries {
      entriesByID[entry.id] = entry
    }
    return entriesByID
  }
}
