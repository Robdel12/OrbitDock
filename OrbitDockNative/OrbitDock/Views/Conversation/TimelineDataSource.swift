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
    let displayedEntries: [ServerConversationRowEntry]

    private let directDisplayIndexByRowID: [String: Int]
    private let groupIndexByChildRowID: [String: Int]
    private let groupSpecsByIndex: [Int: ToolGroupSpec]

    static func make(
      entries: [ServerConversationRowEntry],
      viewMode: ChatViewMode
    ) -> Projection {
      guard viewMode == .focused else {
        let directIndexByRowID = Dictionary(
          uniqueKeysWithValues: entries.enumerated().map { index, entry in
            (entry.id, index)
          }
        )
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

        displayedEntries.append(makeActivityGroupEntry(spec: spec, rawEntriesByID: Dictionary(
          uniqueKeysWithValues: toolBuffer.map { ($0.entry.id, $0.entry) }
        )))
        groupSpecsByIndex[groupIndex] = spec

        for child in archivedTools {
          groupIndexByChildRowID[child.entry.id] = groupIndex
        }

        toolBuffer.removeAll()
      }

      for entry in entries {
        switch entry.row {
          case .tool:
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

    func applyingContentUpdates(
      changedEntries: [ServerConversationRowEntry],
      to displayedEntries: [ServerConversationRowEntry]
    ) -> [ServerConversationRowEntry] {
      guard !changedEntries.isEmpty else { return displayedEntries }

      var updatedEntries = displayedEntries
      let changedEntriesByID = Dictionary(uniqueKeysWithValues: changedEntries.map { ($0.id, $0) })
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

      return updatedEntries
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
    let fallbackEntriesByID = Dictionary(uniqueKeysWithValues: fallbackEntries.map { ($0.id, $0) })
    let archivedTools = spec.archivedToolIDs.compactMap { rowID in
      toolRow(for: rowID, primary: rawEntriesByID, fallback: fallbackEntriesByID)
    }

    let latestTool = toolRow(for: spec.latestToolID, primary: rawEntriesByID, fallback: fallbackEntriesByID)

    let title = archivedTools.count == 1 ? "1 previous tool" : "\(archivedTools.count) previous tools"
    let summary = archivedTools.map(\.title).joined(separator: ", ")
    let allCompleted = archivedTools.allSatisfy { $0.status == .completed }
    let status: ServerConversationToolStatus = allCompleted ? .completed : .running
    let latestFamily = latestTool?.family

    return ServerConversationRowEntry(
      sessionId: spec.sessionId,
      sequence: spec.sequence,
      turnId: spec.turnId,
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

  private static func toolRow(
    for rowID: String,
    primary: [String: ServerConversationRowEntry],
    fallback: [String: ServerConversationRowEntry]
  ) -> ServerConversationToolRow? {
    let entry = primary[rowID] ?? fallback[rowID]
    guard let entry, case let .tool(toolRow) = entry.row else { return nil }
    return toolRow
  }
}
