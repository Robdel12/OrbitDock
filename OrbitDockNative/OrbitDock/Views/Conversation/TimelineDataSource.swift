//
//  TimelineDataSource.swift
//  OrbitDock
//
//  In focused mode, groups consecutive tool rows into activity groups.
//

import Foundation

enum TimelineDataSource {
  /// In focused mode, consecutive tool rows between message rows
  /// collapse into synthetic activityGroup entries.
  static func groupToolRuns(_ rawEntries: [ServerConversationRowEntry]) -> [ServerConversationRowEntry] {
    var result: [ServerConversationRowEntry] = []
    var toolBuffer: [ServerConversationToolRow] = []
    var bufferSessionId = ""
    var bufferStartSequence: UInt64 = 0

    func flushBuffer() {
      guard !toolBuffer.isEmpty else { return }
      if toolBuffer.count == 1 {
        let tool = toolBuffer[0]
        result.append(ServerConversationRowEntry(
          sessionId: bufferSessionId,
          sequence: bufferStartSequence,
          turnId: nil,
          row: .tool(tool)
        ))
      } else {
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
          flushBuffer()
          result.append(entry)

        default:
          flushBuffer()
          result.append(entry)
      }
    }

    flushBuffer()
    return result
  }
}
