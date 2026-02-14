//
//  TurnSummary.swift
//  OrbitDock
//
//  Groups TranscriptMessages into per-turn summaries for the Agent Workbench.
//

import Foundation

// MARK: - Turn Status

enum TurnStatus {
  case active
  case completed
  case failed
}

// MARK: - Turn Summary

struct TurnSummary: Identifiable {
  let id: String           // "turn-1" or synthetic "turn-synth-N"
  let turnNumber: Int
  let startTimestamp: Date?
  let endTimestamp: Date?
  let messages: [TranscriptMessage]
  let toolsUsed: [String]
  let changedFiles: [String]
  let status: TurnStatus
  let diff: String?        // from TurnDiff snapshot
}

// MARK: - Turn Builder

enum TurnBuilder {
  /// Group a flat list of TranscriptMessages into TurnSummaries.
  ///
  /// A turn boundary is a `.user` or `.steer` message. All messages from one boundary
  /// to the next are grouped into a single turn. For Codex direct sessions, turn diffs
  /// from the server are attached by matching turn IDs.
  static func build(
    from messages: [TranscriptMessage],
    serverTurnDiffs: [ServerTurnDiff] = [],
    serverTurnCount: UInt64 = 0,
    currentTurnId: String? = nil
  ) -> [TurnSummary] {
    guard !messages.isEmpty else { return [] }

    // Split messages into groups at turn boundaries
    var groups: [[TranscriptMessage]] = []
    var currentGroup: [TranscriptMessage] = []

    for message in messages {
      let isBoundary = message.type == .user || message.type == .steer
      if isBoundary, !currentGroup.isEmpty {
        groups.append(currentGroup)
        currentGroup = []
      }
      currentGroup.append(message)
    }
    if !currentGroup.isEmpty {
      groups.append(currentGroup)
    }

    // Build turn diff lookup
    let diffByTurnId = Dictionary(uniqueKeysWithValues: serverTurnDiffs.map { ($0.turnId, $0.diff) })

    // Convert groups to TurnSummaries
    return groups.enumerated().map { index, msgs in
      let turnNumber = index + 1
      let syntheticId = "turn-synth-\(turnNumber)"

      // Extract tool names from tool messages
      let tools = msgs
        .filter { $0.type == .tool }
        .compactMap { $0.toolName }
      let uniqueTools = Array(Set(tools))

      // Extract changed files from tool inputs
      let files = msgs
        .filter { $0.type == .tool }
        .compactMap { $0.filePath }
      let uniqueFiles = Array(Set(files))

      // Determine status
      let isLast = index == groups.count - 1
      let hasError = msgs.contains { $0.type == .toolResult && ($0.toolOutput?.contains("error") == true || $0.toolOutput?.contains("Error") == true) }
      let isActive = isLast && (currentTurnId != nil || msgs.contains { $0.isInProgress })
      let status: TurnStatus = isActive ? .active : (hasError ? .failed : .completed)

      // Try to match a server turn diff
      let diff = diffByTurnId[syntheticId]

      return TurnSummary(
        id: syntheticId,
        turnNumber: turnNumber,
        startTimestamp: msgs.first?.timestamp,
        endTimestamp: isActive ? nil : msgs.last?.timestamp,
        messages: msgs,
        toolsUsed: uniqueTools,
        changedFiles: uniqueFiles,
        status: status,
        diff: diff
      )
    }
  }
}
